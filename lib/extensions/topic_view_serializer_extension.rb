# frozen_string_literal: true

module DiscourseRevisedCritiqueImage
  module TopicViewSerializerExtension
    def self.prepended(base)
      base.attributes :revised_critique_image,
                      :revised_critique_image_revision_count,
                      :revised_critique_image_max_revisions,
                      :can_add_revised_critique_image,
                      :can_replace_latest_revised_critique_image
    end

    def revised_critique_image
      latest = history.latest
      return nil if latest.blank?

      {
        revision_number: latest["revision_number"],
        upload_id: latest["upload_id"],
        added_at: latest["created_at"],
        updated_at: latest["updated_at"],
        added_by_user_id: latest["user_id"],
        note: latest["note"],
      }
    end

    def revised_critique_image_revision_count
      history.count
    end

    def revised_critique_image_max_revisions
      history.max
    end

    def can_add_revised_critique_image
      return false if scope&.user.blank?
      Eligibility.check(topic: object.topic, user: scope.user, mode: :add).ok
    end

    def can_replace_latest_revised_critique_image
      return false if scope&.user.blank?
      Eligibility.check(topic: object.topic, user: scope.user, mode: :replace_latest).ok
    end

    private

    def history
      @_revised_critique_history ||= RevisionHistory.for(object.topic)
    end
  end
end
