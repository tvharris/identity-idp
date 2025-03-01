class FakeAnalytics < Analytics
  PiiDetected = Class.new(StandardError)

  include AnalyticsEvents
  prepend Idv::AnalyticsEventsEnhancer

  module PiiAlerter
    def track_event(event, original_attributes = {})
      attributes = original_attributes.dup
      pii_like_keypaths = attributes.delete(:pii_like_keypaths) || []

      constant_name = Analytics.constants.find { |c| Analytics.const_get(c) == event }

      string_payload = attributes.to_json

      if string_payload.include?('pii') && !pii_like_keypaths.include?([:pii])
        raise PiiDetected, <<~ERROR
          track_event string 'pii' detected in attributes
          event: #{event} (#{constant_name})
          full event: #{attributes}"
        ERROR
      end

      Idp::Constants::MOCK_IDV_APPLICANT.slice(
        :first_name,
        :last_name,
        :address1,
        :zipcode,
        :dob,
        :state_id_number,
      ).each do |key, default_pii_value|
        if string_payload.match?(Regexp.new('\b' + Regexp.quote(default_pii_value) + '\b', 'i'))
          raise PiiDetected, <<~ERROR
            track_event example PII #{key} (#{default_pii_value}) detected in attributes
            event: #{event} (#{constant_name})
            full event: #{attributes}"
          ERROR
        end
      end

      pii_attr_names = Pii::Attributes.members + [:personal_key] - [
        :state, # state on its own is not enough to be a pii leak
      ]

      check_recursive = ->(value, keypath = []) do
        case value
        when Hash
          value.each do |key, val|
            current_keypath = keypath + [key]
            if pii_attr_names.include?(key) && !pii_like_keypaths.include?(current_keypath)
              raise PiiDetected, <<~ERROR
                track_event received pii key path: #{current_keypath.inspect}
                event: #{event} (#{constant_name})
                full event: #{attributes.inspect}
                allowlisted keypaths: #{pii_like_keypaths.inspect}
              ERROR
            end

            check_recursive.call(val, current_keypath)
          end
        when Array
          value.each { |val| check_recursive.call(val, keypath) }
        end
      end

      check_recursive.call(attributes)

      super(event, attributes)
    end
  end

  UndocumentedParams = Class.new(StandardError)

  module UndocumentedParamsChecker
    mattr_accessor :allowed_extra_analytics
    mattr_accessor :asts
    mattr_accessor :docstrings

    def track_event(event, original_attributes = {})
      method_name = caller.
        grep(/analytics_events\.rb/)&.
        first&.
        match(/:in `(?<method_name>[^']+)'/)&.[](:method_name)

      if method_name && !allowed_extra_analytics.include?(:*)
        analytics_method = AnalyticsEvents.instance_method(method_name)

        param_names = analytics_method.
          parameters.
          select { |type, _name| [:keyreq, :key].include?(type) }.
          map(&:last)

        extra_keywords = original_attributes.keys \
          - [:pii_like_keypaths, :user_id] \
          - Array(allowed_extra_analytics) \
          - param_names \
          - option_param_names(analytics_method)

        if extra_keywords.present?
          raise UndocumentedParams, <<~ERROR
            event :#{method_name} called with undocumented params #{extra_keywords.inspect}
            (if these params are for specs only, use :allowed_extra_analytics metadata)
          ERROR
        end
      end

      super(event, original_attributes)
    end

    # @api private
    # Returns the names of @option tags from the source of a method
    def option_param_names(instance_method)
      self.asts ||= {}
      self.docstrings ||= {}

      if !YARD::Tags::Library.instance.has_tag?(:'identity.idp.previous_event_name')
        YARD::Tags::Library.define_tag('Previous Event Name', :'identity.idp.previous_event_name')
      end

      file = instance_method.source_location.first

      ast = self.asts[file] ||= begin
        YARD::Parser::Ruby::RubyParser.new(File.read(file), file).
          parse.
          ast
      end

      docstring = self.docstrings[instance_method.name] ||= begin
        node = ast.traverse do |node|
          break node if node.type == :def && node.jump(:ident)&.first == instance_method.name.to_s
        end

        YARD::DocstringParser.new.parse(node.docstring).to_docstring
      end

      docstring.tags.select { |tag| tag.tag_name == 'option' }.
        map { |tag| tag.pair.name.tr(%('"), '') }
    end
  end

  prepend PiiAlerter
  prepend UndocumentedParamsChecker

  attr_reader :events
  attr_accessor :user

  def initialize(user: AnonymousUser.new)
    @events = Hash.new
    @user = user
  end

  def track_event(event, attributes = {})
    if attributes[:proofing_components].instance_of?(Idv::ProofingComponentsLogging)
      attributes[:proofing_components] = attributes[:proofing_components].as_json.symbolize_keys
    end
    events[event] ||= []
    events[event] << attributes
    nil
  end

  def track_mfa_submit_event(_attributes)
    # no-op
  end

  def browser_attributes
    {}
  end
end

RSpec.configure do |c|
  c.around do |ex|
    keys = Array(ex.metadata[:allowed_extra_analytics])
    FakeAnalytics::UndocumentedParamsChecker.allowed_extra_analytics = keys
    ex.run
  ensure
    FakeAnalytics::UndocumentedParamsChecker.allowed_extra_analytics = []
  end
end

RSpec::Matchers.define :have_logged_event do |event, attributes_matcher|
  match do |actual|
    if event.nil? && attributes_matcher.nil?
      expect(actual.events.count).to be > 0
    elsif attributes_matcher.nil?
      expect(actual.events).to have_key(event)
    else
      expect(actual.events[event]).to include(match(attributes_matcher))
    end
  end

  failure_message do |actual|
    matching_events = actual.events[event]
    if matching_events&.length == 1 && attributes_matcher.instance_of?(Hash)
      # We found one matching event. Let's show the user a diff of the actual and expected
      # attributes
      expected = attributes_matcher
      actual = matching_events.first
      message = "Expected that FakeAnalytics would have received matching event #{event}\n"
      message += "expected: #{expected}\n"
      message += "     got: #{actual}\n\n"
      message += "Diff:#{differ.diff(actual, expected)}"
      message
    elsif matching_events&.length == 1 &&
          attributes_matcher.instance_of?(RSpec::Matchers::BuiltIn::Include)
      # We found one matching event and an `include` matcher. Let's show the user a diff of the
      # actual and expected attributes
      expected = attributes_matcher.expecteds.first
      actual_attrs = matching_events.first
      actual_compared = actual_attrs.slice(*expected.keys)
      actual_ignored = actual_attrs.except(*expected.keys)
      message = "Expected that FakeAnalytics would have received matching event #{event}"
      message += "expected: include #{expected}\n"
      message += "     got: #{actual_attrs}\n\n"
      message += "Diff:#{differ.diff(actual_compared, expected)}\n"
      message += "Attributes ignored by the include matcher:#{differ.diff(
        actual_ignored, {}
      )}"
      message
    else
      <<~MESSAGE
        Expected that FakeAnalytics would have received event #{event.inspect}
        with #{attributes_matcher.inspect}.

        Events received:
        #{actual.events.pretty_inspect}
      MESSAGE
    end
  end

  def differ
    RSpec::Support::Differ.new(
      object_preparer: lambda do |object|
                         RSpec::Matchers::Composable.surface_descriptions_in(object)
                       end,
      color: RSpec::Matchers.configuration.color?,
    )
  end
end
