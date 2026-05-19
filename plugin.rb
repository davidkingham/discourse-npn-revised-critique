# frozen_string_literal: true

# name: discourse-revised-critique-image
# about: Lets the OP of an image critique topic share a revised version after receiving feedback.
# version: 2.0.0
# authors: David Kingham
# url: https://github.com/davidkingham/discourse-revised-critique-image
# license: MIT

enabled_site_setting :revised_critique_enabled

register_asset "stylesheets/revised-critique-image.scss"

register_svg_icon "image"
register_svg_icon "arrows-rotate"
register_svg_icon "plus"

module ::DiscourseRevisedCritiqueImage
  PLUGIN_NAME = "discourse-revised-critique-image"

  # JSON-encoded history of every revision a topic has had. Source of truth
  # from v2.0 onwards. Each entry shape is documented in RevisionHistory.
  REVISED_IMAGE_HISTORY = "revised_image_history"

  # Denormalised "latest revision" fields. Kept in sync with the last entry
  # of the history so that legacy serializers and external integrations can
  # read the current state without parsing the JSON.
  REVISED_IMAGE_UPLOAD_ID = "revised_image_upload_id"
  REVISED_IMAGE_ADDED_AT = "revised_image_added_at"
  REVISED_IMAGE_ADDED_BY_USER_ID = "revised_image_added_by_user_id"
  REVISED_IMAGE_NOTE = "revised_image_note"
end

require_relative "lib/discourse_revised_critique_image/engine"

after_initialize do
  require_relative "app/controllers/discourse_revised_critique_image/revisions_controller"
  require_relative "lib/discourse_revised_critique_image/revision_history"
  require_relative "lib/discourse_revised_critique_image/revision_adder"
  require_relative "lib/discourse_revised_critique_image/eligibility"
  require_relative "lib/extensions/topic_view_serializer_extension"

  Discourse::Application.routes.append do
    mount ::DiscourseRevisedCritiqueImage::Engine, at: "/revised-critique-image"
  end

  Topic.register_custom_field_type(DiscourseRevisedCritiqueImage::REVISED_IMAGE_HISTORY, :json)
  Topic.register_custom_field_type(DiscourseRevisedCritiqueImage::REVISED_IMAGE_UPLOAD_ID, :integer)
  Topic.register_custom_field_type(
    DiscourseRevisedCritiqueImage::REVISED_IMAGE_ADDED_BY_USER_ID,
    :integer,
  )
  Topic.register_custom_field_type(DiscourseRevisedCritiqueImage::REVISED_IMAGE_ADDED_AT, :string)
  Topic.register_custom_field_type(DiscourseRevisedCritiqueImage::REVISED_IMAGE_NOTE, :string)

  TopicList.preloaded_custom_fields << DiscourseRevisedCritiqueImage::REVISED_IMAGE_UPLOAD_ID

  TopicViewSerializer.prepend DiscourseRevisedCritiqueImage::TopicViewSerializerExtension
end
