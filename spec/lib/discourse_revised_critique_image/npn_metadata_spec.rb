# frozen_string_literal: true

describe DiscourseRevisedCritiqueImage::NpnMetadata do
  fab!(:owner, :user)
  fab!(:topic) { Fabricate(:topic, user: owner) }
  fab!(:first_post) { Fabricate(:post, topic: topic, user: owner, raw: "Original.") }

  let(:fields) { DiscourseRevisedCritiqueImage::NpnMetadata }

  def upload(filename: "r.png", width: 800, height: 600)
    Fabricate(:upload, user: owner, original_filename: filename, width: width, height: height)
  end

  def entry(upload:, number:, note: nil, user: owner, created_at: Time.zone.now.iso8601)
    {
      "revision_number" => number,
      "upload_id" => upload.id,
      "upload_short_url" => upload.short_url,
      "width" => upload.width,
      "height" => upload.height,
      "note" => note,
      "user_id" => user.id,
      "created_at" => created_at,
      "updated_at" => created_at,
    }
  end

  describe ".apply!" do
    it "writes count, latest fields, the ordered images array, and the schema marker" do
      u1 = upload(filename: "r1.png")
      u2 = upload(filename: "r2.png")
      entries = [entry(upload: u1, number: 1, note: "first"), entry(upload: u2, number: 2)]

      fields.apply!(topic, entries)

      expect(topic.custom_fields[fields::REVISION_COUNT]).to eq(2)
      expect(topic.custom_fields[fields::LATEST_REVISION_UPLOAD_ID]).to eq(u2.id)
      expect(topic.custom_fields[fields::LATEST_REVISION_IMAGE_URL]).to eq(u2.url)
      expect(topic.custom_fields[fields::SCHEMA]).to eq(fields::SCHEMA_VERSION)

      images = topic.custom_fields[fields::REVISION_IMAGES]
      expect(images.length).to eq(2)
      expect(images[0]).to include(
        "revision_number" => 1,
        "upload_id" => u1.id,
        "image_url" => u1.url,
        "post_id" => first_post.id,
        "user_id" => owner.id,
        "note" => "first",
      )
      expect(images[1]).to include(
        "revision_number" => 2,
        "upload_id" => u2.id,
        "image_url" => u2.url,
        "post_id" => first_post.id,
        "user_id" => owner.id,
      )
      expect(images[1]).not_to have_key("note")
    end

    it "writes empty/zero values for a topic with no revisions" do
      fields.apply!(topic, [])

      expect(topic.custom_fields[fields::REVISION_COUNT]).to eq(0)
      expect(topic.custom_fields[fields::LATEST_REVISION_UPLOAD_ID]).to be_nil
      expect(topic.custom_fields[fields::LATEST_REVISION_IMAGE_URL]).to be_nil
      expect(topic.custom_fields[fields::REVISION_IMAGES]).to eq([])
      expect(topic.custom_fields[fields::SCHEMA]).to eq(fields::SCHEMA_VERSION)
    end

    it "deduplicates by upload_id and keeps the first occurrence" do
      u1 = upload(filename: "r1.png")
      entries = [
        entry(upload: u1, number: 1, note: "first"),
        entry(upload: u1, number: 2, note: "retry"),
      ]

      fields.apply!(topic, entries)

      images = topic.custom_fields[fields::REVISION_IMAGES]
      expect(images.length).to eq(1)
      expect(images[0]).to include("revision_number" => 1, "note" => "first")
    end

    it "does not overwrite a schema version that is already set" do
      topic.custom_fields[fields::SCHEMA] = 99
      topic.save_custom_fields(true)

      fields.apply!(topic, [entry(upload: upload, number: 1)])

      expect(topic.custom_fields[fields::SCHEMA]).to eq(99)
    end

    it "skips entries whose upload no longer exists" do
      u1 = upload(filename: "r1.png")
      u2 = upload(filename: "r2.png")
      ghost_id = u2.id
      u2.destroy!

      entries =
        [entry(upload: u1, number: 1)].tap do |list|
          list << entry(upload: u1, number: 2).merge("upload_id" => ghost_id)
        end

      fields.apply!(topic, entries)

      images = topic.custom_fields[fields::REVISION_IMAGES]
      expect(images.length).to eq(1)
      expect(images[0]["upload_id"]).to eq(u1.id)
      expect(topic.custom_fields[fields::LATEST_REVISION_UPLOAD_ID]).to eq(u1.id)
    end
  end
end
