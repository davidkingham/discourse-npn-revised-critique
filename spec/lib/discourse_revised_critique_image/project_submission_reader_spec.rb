# frozen_string_literal: true

describe DiscourseRevisedCritiqueImage::ProjectSubmissionReader do
  fab!(:owner, :user)
  fab!(:topic) { Fabricate(:topic, user: owner, title: "Project critique topic title") }
  fab!(:first_post) { Fabricate(:post, topic: topic, user: owner, raw: "Plain non-project body.") }

  subject(:result) { described_class.read(topic.reload) }

  let(:submission_type_key) { DiscourseRevisedCritiqueImage::SubmissionsCompat.submission_type_key }
  let(:data_key) { DiscourseRevisedCritiqueImage::SubmissionsCompat.project_data_key }
  let(:begin_marker) { DiscourseRevisedCritiqueImage::SubmissionsCompat.block_begin }
  let(:end_marker) { DiscourseRevisedCritiqueImage::SubmissionsCompat.block_end }

  def make_image(overrides = {})
    {
      "id" => "a1b2c3d4e5f60718",
      "position" => 1,
      "upload_id" => 42,
      "short_url" => "upload://abc.jpeg",
      "caption" => "",
      "alt" => "Image 1",
    }.merge(overrides)
  end

  def mark_as_project!(images: [make_image])
    topic.custom_fields[submission_type_key] = "project_critique"
    topic.custom_fields[data_key] = {
      "type" => "project_critique",
      "version" => 1,
      "images" => images,
    }
    topic.save_custom_fields(true)
  end

  def wrap_with_markers!(post)
    body = [begin_marker, "<!-- generated grid html -->", end_marker, "outside the block"].join(
      "\n\n",
    )
    post.update!(raw: body)
  end


  describe "single-image (non-project) topics" do
    it "returns project? = false and valid? = false with no error_key" do
      expect(result.project?).to eq(false)
      expect(result.valid?).to eq(false)
      expect(result.error_key).to be_nil
      expect(result.image_count).to eq(0)
      expect(result.images).to eq([])
    end
  end

  describe "well-formed project topic" do
    before do
      mark_as_project!(images: [make_image, make_image("position" => 2, "alt" => "Image 2")])
      wrap_with_markers!(first_post)
    end

    it "is detected and valid" do
      expect(result.project?).to eq(true)
      expect(result.valid?).to eq(true)
      expect(result.error_key).to be_nil
      expect(result.image_count).to eq(2)
    end

    it "returns marker offsets in correct order" do
      expect(result.begin_offset).to be_a(Integer)
      expect(result.end_offset).to be_a(Integer)
      expect(result.end_offset).to be > result.begin_offset
    end

    it "exposes the marker constants used" do
      expect(result.begin_marker).to eq(begin_marker)
      expect(result.end_marker).to eq(end_marker)
    end

    it "normalizes captions to String even when source omits them" do
      mark_as_project!(images: [make_image.tap { |h| h.delete("caption") }])
      wrap_with_markers!(first_post)
      expect(result.images.first["caption"]).to eq("")
    end
  end

  describe "validation failures" do
    before { mark_as_project!(images: [make_image]) }

    it "fails when the data field is missing" do
      topic.custom_fields[data_key] = nil
      topic.save_custom_fields(true)

      expect(result.project?).to eq(true)
      expect(result.valid?).to eq(false)
      expect(result.error_key).to eq(:no_submission_data)
    end

    it "fails when type is wrong" do
      topic.custom_fields[data_key] = { "type" => "image_critique", "version" => 1, "images" => [] }
      topic.save_custom_fields(true)

      expect(result.error_key).to eq(:wrong_type)
    end

    it "fails when version is unsupported" do
      topic.custom_fields[data_key] = {
        "type" => "project_critique",
        "version" => 2,
        "images" => [make_image],
      }
      topic.save_custom_fields(true)

      expect(result.error_key).to eq(:wrong_version)
    end

    it "fails when images is not an Array" do
      topic.custom_fields[data_key] = {
        "type" => "project_critique",
        "version" => 1,
        "images" => "nope",
      }
      topic.save_custom_fields(true)

      expect(result.error_key).to eq(:images_not_array)
    end

    it "fails when there are zero images" do
      topic.custom_fields[data_key] = {
        "type" => "project_critique",
        "version" => 1,
        "images" => [],
      }
      topic.save_custom_fields(true)

      expect(result.error_key).to eq(:image_count_out_of_range)
    end

    it "fails when there are more than 12 images" do
      thirteen = (1..13).map { |i| make_image("position" => i, "alt" => "Image #{i}") }
      topic.custom_fields[data_key] = {
        "type" => "project_critique",
        "version" => 1,
        "images" => thirteen,
      }
      topic.save_custom_fields(true)

      expect(result.error_key).to eq(:image_count_out_of_range)
    end

    it "fails when an image is missing required fields" do
      bad = make_image.tap { |h| h.delete("id") }
      topic.custom_fields[data_key] = {
        "type" => "project_critique",
        "version" => 1,
        "images" => [bad],
      }
      topic.save_custom_fields(true)

      expect(result.error_key).to eq(:image_missing_fields)
    end

    it "fails when upload_id is nil" do
      bad = make_image("upload_id" => nil)
      topic.custom_fields[data_key] = {
        "type" => "project_critique",
        "version" => 1,
        "images" => [bad],
      }
      topic.save_custom_fields(true)

      expect(result.error_key).to eq(:image_missing_fields)
    end

    it "fails when markers are missing from the first post" do
      first_post.update!(raw: "no markers here, just text")
      expect(result.error_key).to eq(:markers_missing)
    end

    it "fails when only the begin marker is present" do
      first_post.update!(raw: "#{begin_marker}\n\nbut no end")
      expect(result.error_key).to eq(:markers_missing)
    end

    it "fails when markers appear in reversed order" do
      first_post.update!(raw: "#{end_marker}\n\nreversed\n\n#{begin_marker}")
      expect(result.error_key).to eq(:markers_reversed)
    end

    it "fails when the first post does not exist" do
      first_post.destroy!
      expect(result.error_key).to eq(:missing_first_post)
    end
  end

  describe "non-mutation guarantee" do
    before do
      mark_as_project!(images: [make_image])
      wrap_with_markers!(first_post)
    end

    it "does not mutate topic.custom_fields" do
      before_fields = topic.reload.custom_fields.deep_dup
      described_class.read(topic)
      expect(topic.reload.custom_fields).to eq(before_fields)
    end

    it "does not mutate post.raw" do
      before_raw = first_post.reload.raw
      described_class.read(topic)
      expect(first_post.reload.raw).to eq(before_raw)
    end
  end
end
