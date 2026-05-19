# frozen_string_literal: true

module DiscourseRevisedCritiqueImage
  # Read/write the revision history stored on a topic's custom fields.
  #
  # Entry shape:
  #   {
  #     "revision_number" => 1,         # 1-indexed, strictly increasing per add
  #     "upload_id"       => 123,
  #     "upload_short_url"=> "upload://abc.png",
  #     "width"           => 800,       # may be nil
  #     "height"          => 600,       # may be nil
  #     "note"            => "...",     # may be nil
  #     "user_id"         => 45,        # who created or last replaced
  #     "created_at"      => iso8601,   # original add time
  #     "updated_at"      => iso8601,   # replacement time (== created_at if never replaced)
  #   }
  class RevisionHistory
    def self.for(topic)
      new(topic)
    end

    def initialize(topic)
      @topic = topic
    end

    # Returns the full list, oldest first, backfilling from legacy v1.2 scalar
    # fields if the JSON history has never been written.
    def entries
      @entries ||= load_entries
    end

    def count
      entries.size
    end

    def latest
      entries.last
    end

    def empty?
      entries.empty?
    end

    def at_max?
      count >= max
    end

    def max
      [SiteSetting.revised_critique_max_revisions.to_i, 1].max
    end

    # Append a new entry. Returns the new entry.
    def add!(upload:, user:, note:)
      entry =
        build_entry(
          upload: upload,
          user: user,
          note: note,
          revision_number: next_revision_number
        )
      mutated = entries + [entry]
      persist!(mutated)
      entry
    end

    # Mutate the latest entry's fields in place. Returns the updated entry.
    # Preserves the latest entry's revision_number and created_at; updates
    # everything else, including updated_at.
    def replace_latest!(upload:, user:, note:)
      raise "no revision to replace" if empty?

      latest_entry = entries.last.dup
      latest_entry["upload_id"] = upload.id
      latest_entry["upload_short_url"] = upload.short_url
      latest_entry["width"] = (
        if upload.width.to_i.positive?
          upload.width.to_i
        else
          nil
        end
      )
      latest_entry["height"] = (
        if upload.height.to_i.positive?
          upload.height.to_i
        else
          nil
        end
      )
      latest_entry["note"] = note.presence
      latest_entry["user_id"] = user.id
      latest_entry["updated_at"] = Time.zone.now.iso8601

      mutated = entries[0...-1] + [latest_entry]
      persist!(mutated)
      latest_entry
    end

    private

    def next_revision_number
      empty? ? 1 : (entries.last["revision_number"].to_i + 1)
    end

    def build_entry(upload:, user:, note:, revision_number:)
      now = Time.zone.now.iso8601
      {
        "revision_number" => revision_number,
        "upload_id" => upload.id,
        "upload_short_url" => upload.short_url,
        "width" => upload.width.to_i.positive? ? upload.width.to_i : nil,
        "height" => upload.height.to_i.positive? ? upload.height.to_i : nil,
        "note" => note.presence,
        "user_id" => user.id,
        "created_at" => now,
        "updated_at" => now
      }
    end

    def persist!(new_entries)
      @entries = new_entries
      @topic.custom_fields[REVISED_IMAGE_HISTORY] = new_entries
      sync_denormalised_fields!(new_entries.last)
      @topic.save_custom_fields(true)
    end

    # Keep the v1.2 scalar fields pointing at the latest entry so they remain
    # a valid "current state" snapshot for any external consumer.
    def sync_denormalised_fields!(latest_entry)
      return if latest_entry.blank?

      @topic.custom_fields[REVISED_IMAGE_UPLOAD_ID] = latest_entry["upload_id"]
      @topic.custom_fields[REVISED_IMAGE_ADDED_AT] = latest_entry["updated_at"]
      @topic.custom_fields[REVISED_IMAGE_ADDED_BY_USER_ID] = latest_entry[
        "user_id"
      ]
      @topic.custom_fields[REVISED_IMAGE_NOTE] = latest_entry["note"]
    end

    def load_entries
      raw = @topic.custom_fields[REVISED_IMAGE_HISTORY]
      return raw.dup if raw.is_a?(Array) && raw.any?

      # Backfill: a v1.2 topic with a single revision recorded only in the
      # scalar fields. Treat it as Revision 1.
      legacy_upload_id = @topic.custom_fields[REVISED_IMAGE_UPLOAD_ID]
      return [] if legacy_upload_id.blank?

      legacy_upload = Upload.find_by(id: legacy_upload_id.to_i)
      return [] if legacy_upload.blank?

      [
        {
          "revision_number" => 1,
          "upload_id" => legacy_upload.id,
          "upload_short_url" => legacy_upload.short_url,
          "width" =>
            legacy_upload.width.to_i.positive? ? legacy_upload.width.to_i : nil,
          "height" =>
            (
              if legacy_upload.height.to_i.positive?
                legacy_upload.height.to_i
              else
                nil
              end
            ),
          "note" => @topic.custom_fields[REVISED_IMAGE_NOTE].presence,
          "user_id" =>
            @topic.custom_fields[REVISED_IMAGE_ADDED_BY_USER_ID]&.to_i,
          "created_at" =>
            @topic.custom_fields[REVISED_IMAGE_ADDED_AT].presence ||
              Time.zone.now.iso8601,
          "updated_at" =>
            @topic.custom_fields[REVISED_IMAGE_ADDED_AT].presence ||
              Time.zone.now.iso8601
        }
      ]
    end
  end
end
