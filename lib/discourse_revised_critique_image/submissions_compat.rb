# frozen_string_literal: true

module DiscourseRevisedCritiqueImage
  # Thin compatibility wrapper around the public contract published by
  # discourse-npn-submissions. Lets us reference the sibling plugin's
  # constants when they're loaded (the source of truth) while still
  # functioning when the sibling plugin is disabled or hasn't finished
  # initializing yet.
  #
  # Resolution is lazy: constants are only looked up on first call, so
  # plugin load order doesn't matter — by the time a request reaches
  # `ProjectSubmissionReader`, both plugins' `after_initialize` blocks
  # have run and the canonical constants (if any) are available.
  #
  # The fallback string values mirror the contract documented in the
  # submissions plugin's `TopicMetadata` and `ProjectPostBuilder` modules.
  # If those values ever change upstream, we want the constant lookup
  # (not these fallbacks) to win — hence the prefer-defined-constants order.
  module SubmissionsCompat
    FALLBACK_PROJECT_DATA_KEY = "npn_project_submission_data"
    FALLBACK_BLOCK_BEGIN = "<!-- npn-project-submission:begin -->"
    FALLBACK_BLOCK_END = "<!-- npn-project-submission:end -->"
    FALLBACK_SUBMISSION_TYPE_KEY = "npn_submission_type"

    module_function

    # The topic custom_field key holding the structured project payload.
    def project_data_key
      if defined?(::DiscourseNpnSubmissions::TopicMetadata::PROJECT_SUBMISSION_DATA_KEY)
        ::DiscourseNpnSubmissions::TopicMetadata::PROJECT_SUBMISSION_DATA_KEY
      else
        FALLBACK_PROJECT_DATA_KEY
      end
    end

    # The topic custom_field key recording which submission flow produced
    # this topic. Currently not published as a public constant by the
    # submissions plugin's docs, but the literal string is part of its
    # documented contract.
    def submission_type_key
      if defined?(::DiscourseNpnSubmissions::TopicMetadata::SUBMISSION_TYPE_KEY)
        ::DiscourseNpnSubmissions::TopicMetadata::SUBMISSION_TYPE_KEY
      else
        FALLBACK_SUBMISSION_TYPE_KEY
      end
    end

    def block_begin
      if defined?(::DiscourseNpnSubmissions::ProjectPostBuilder::PROJECT_BLOCK_BEGIN)
        ::DiscourseNpnSubmissions::ProjectPostBuilder::PROJECT_BLOCK_BEGIN
      else
        FALLBACK_BLOCK_BEGIN
      end
    end

    def block_end
      if defined?(::DiscourseNpnSubmissions::ProjectPostBuilder::PROJECT_BLOCK_END)
        ::DiscourseNpnSubmissions::ProjectPostBuilder::PROJECT_BLOCK_END
      else
        FALLBACK_BLOCK_END
      end
    end

    # ---- The photographer's hang (exhibition wall) ---------------------------
    # The submissions plugin owns the hang's shape, the wall picture's markup
    # and the submission record. Each helper degrades to "no hang" when that
    # plugin (or a new enough version of it) isn't loaded, so a revision still
    # saves and renders with the plain Project Overview.

    # A hang normalized against the submissions plugin's allowlist, with
    # string keys for JSON storage; nil when absent or it can't be checked.
    def normalize_hang(raw)
      return nil unless raw.is_a?(Hash)
      return nil unless defined?(::DiscourseNpnSubmissions::ProjectHang)
      ::DiscourseNpnSubmissions::ProjectHang.normalize(raw).deep_stringify_keys.presence
    rescue StandardError
      nil
    end

    # Markdown for a drawn wall picture (heading + wrapper + image), or nil.
    def hang_markup(upload:, count:, intent:)
      return nil if upload.blank?
      builder =
        defined?(::DiscourseNpnSubmissions::ProjectPostBuilder) &&
          ::DiscourseNpnSubmissions::ProjectPostBuilder
      return nil unless builder && builder.respond_to?(:hang_markup)
      builder.hang_markup(upload: upload, count: count, intent: intent)
    rescue StandardError
      nil
    end

    def submission_for(topic)
      return nil unless defined?(::DiscourseNpnSubmissions::Submission)
      ::DiscourseNpnSubmissions::Submission.find_by(topic_id: topic.id)
    rescue StandardError
      nil
    end

    # The presentation goal chosen in the project form ("gallery", "book", …).
    def project_intent(topic)
      submission_for(topic)&.field("project_intent").presence
    rescue StandardError
      nil
    end

    # The upload id of the wall picture drawn for the ORIGINAL submission.
    def original_hang_image_upload_id(topic)
      submission = submission_for(topic)
      return nil unless submission.respond_to?(:hang_image_upload)
      submission.hang_image_upload&.id
    rescue StandardError
      nil
    end

    # True when the sibling plugin's namespace is loaded — useful in tests
    # and in any future log line that wants to record which source was
    # used to resolve the constants.
    def submissions_loaded?
      defined?(::DiscourseNpnSubmissions) ? true : false
    end
  end
end
