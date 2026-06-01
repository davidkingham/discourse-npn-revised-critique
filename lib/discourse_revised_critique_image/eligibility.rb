# frozen_string_literal: true

module DiscourseRevisedCritiqueImage
  # Centralises the rules that decide whether a given user can add or replace
  # a revised image on a given topic. Used by both the controller (to
  # authorise the mutation) and the serializer (to drive whether the frontend
  # buttons are shown).
  class Eligibility
    MODES = %i[add replace_latest].freeze

    Result = Struct.new(:ok, :error_key, keyword_init: true)

    def self.check(topic:, user:, mode: :add)
      new(topic: topic, user: user, mode: mode).check
    end

    def initialize(topic:, user:, mode: :add)
      @topic = topic
      @user = user
      @mode = mode.to_sym
    end

    def check
      return failure(:invalid_mode) if MODES.exclude?(@mode)
      return failure(:plugin_disabled) unless SiteSetting.revised_critique_enabled
      return failure(:not_owner) if @user.blank?
      return failure(:not_owner) if @user.respond_to?(:suspended?) && @user.suspended?
      return failure(:not_owner) unless @topic.user_id == @user.id
      return failure(:not_in_category) unless in_configured_category?
      # Defensive gate: a project-critique topic from discourse-npn-submissions
      # carries a structured payload (and post-body markers) that the
      # single-image flow would corrupt by rewriting the first post. Refuse
      # both add and replace_latest until the project revision editor lands.
      return failure(:project_topic_unsupported) if project_topic?
      return failure(:cannot_edit_post) unless topic_editable?
      return failure(:cannot_edit_post) unless first_post_editable?
      return failure(:no_replies) if require_reply? && !has_other_user_reply?

      case @mode
      when :add
        return failure(:max_revisions_reached) if history.at_max?
      when :replace_latest
        return failure(:no_revision_to_replace) if history.empty?
      end

      Result.new(ok: true)
    end

    def can?
      check.ok
    end

    private

    def history
      @history ||= RevisionHistory.for(@topic)
    end

    def in_configured_category?
      category_id = SiteSetting.revised_critique_category_id.to_i
      category_id > 0 && @topic.category_id == category_id
    end

    def topic_editable?
      return false if @topic.closed?
      return false if @topic.archived?
      return false if @topic.deleted_at.present?
      true
    end

    def first_post_editable?
      first_post = @topic.first_post
      return false if first_post.blank?
      return false if first_post.deleted_at.present?
      Guardian.new(@user).can_edit?(first_post)
    end

    def require_reply?
      SiteSetting.revised_critique_require_reply_from_other_user
    end

    def has_other_user_reply?
      Post
        .where(topic_id: @topic.id, deleted_at: nil)
        .where("post_number > 1")
        .where("user_id <> ?", @topic.user_id)
        .exists?
    end

    # Treat any topic the reader recognises as a project critique as off
    # limits for the single-image flow. A reader exception is swallowed and
    # treated as "not a project" so a bug in the reader can't lock out
    # legitimate single-image users; the reader's own non-mutation guarantee
    # means the worst case is that single-image proceeds on a topic the
    # reader couldn't classify, which is the existing pre-Phase-2 behaviour.
    def project_topic?
      ProjectSubmissionReader.read(@topic).project?
    rescue => e
      Rails.logger.warn(
        "discourse-revised-critique-image: project_topic? probe raised for " \
          "topic #{@topic&.id}: #{e.class}: #{e.message}",
      )
      false
    end

    def failure(key)
      Result.new(ok: false, error_key: key)
    end
  end
end
