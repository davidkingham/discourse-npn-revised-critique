# frozen_string_literal: true

module DiscourseRevisedCritiqueImage
  # Writes a lightweight, durable snapshot of the topic's revision images to
  # NPN-namespaced topic custom fields. Sibling NPN plugins
  # (discourse-npn-submissions for the original image, discourse-npn-critique-reply
  # as the consumer) read these fields directly so they never need to scrape
  # the topic body.
  #
  # This module ONLY writes the revision side. It must never touch the
  # `npn_original_*` fields owned by discourse-npn-submissions.
  module NpnMetadata
    # ---- Field names (read by discourse-npn-critique-reply) ----
    REVISION_COUNT = "npn_revision_count"
    LATEST_REVISION_UPLOAD_ID = "npn_latest_revision_upload_id"
    LATEST_REVISION_IMAGE_URL = "npn_latest_revision_image_url"
    REVISION_IMAGES = "npn_revision_images"
    SCHEMA = "npn_critique_image_version_schema"

    # Shared schema marker. Bump only with a coordinated change across
    # all NPN critique plugins.
    SCHEMA_VERSION = 1

    # Build and apply the npn_* fields from the canonical history entries.
    # Assigns to topic.custom_fields but does NOT save — the caller is expected
    # to be in the middle of a save_custom_fields call so the assignments
    # persist atomically with the rest of the revision update.
    def self.apply!(topic, history_entries)
      images = build_images(topic, history_entries)
      latest = images.last

      topic.custom_fields[REVISION_COUNT] = images.length
      topic.custom_fields[LATEST_REVISION_UPLOAD_ID] = latest && latest["upload_id"]
      topic.custom_fields[LATEST_REVISION_IMAGE_URL] = latest && latest["image_url"]
      topic.custom_fields[REVISION_IMAGES] = images

      topic.custom_fields[SCHEMA] = SCHEMA_VERSION if topic.custom_fields[SCHEMA].blank?
    end

    # Construct the ordered image array consumed by the critique reply plugin.
    # Derived freshly from history.entries on every write, which makes this
    # self-healing: a previously malformed or missing npn_revision_images value
    # is simply overwritten with a valid array on the next revision.
    #
    # Dedupes by upload_id (first occurrence wins) so an accidental retry that
    # appended the same upload twice to the history surfaces only once here.
    def self.build_images(topic, history_entries)
      first_post_id = topic.first_post&.id

      ids = Array(history_entries).map { |e| e["upload_id"] }.compact.map(&:to_i).uniq
      uploads_by_id = ids.any? ? Upload.where(id: ids).index_by(&:id) : {}

      seen = {}
      Array(history_entries).each do |entry|
        upload_id = entry["upload_id"].to_i
        next if upload_id.zero?
        next if seen.key?(upload_id)

        upload = uploads_by_id[upload_id]
        image_url = upload&.url
        next if image_url.blank?

        object = {
          "revision_number" => entry["revision_number"].to_i,
          "upload_id" => upload_id,
          "image_url" => image_url,
          "created_at" => entry["created_at"],
          "post_id" => first_post_id,
          "user_id" => entry["user_id"],
        }
        # Only include note when one was actually captured. The full revision
        # explanation is already constrained by revised_critique_note_max_length
        # at the controller; if a future flow ever produced a very long note,
        # downstream readers can truncate further.
        note = entry["note"]
        object["note"] = note if note.present?

        seen[upload_id] = object
      end

      seen.values
    end
  end
end
