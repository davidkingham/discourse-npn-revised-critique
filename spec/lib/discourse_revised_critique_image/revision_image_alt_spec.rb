# frozen_string_literal: true

# Covers the lightbox-facing alt text for single-image revisions:
# "Revision N - filename.jpg", the additive original_filename history field,
# filename sanitization, and the fallbacks for entries written before the
# field existed. Drives the public RevisionAdder.call and asserts on the
# rendered first-post raw, mirroring the atomicity spec's setup.
describe DiscourseRevisedCritiqueImage::RevisionAdder do
  fab!(:category)
  fab!(:owner) { Fabricate(:user, trust_level: TrustLevel[1]) }
  fab!(:other_user) { Fabricate(:user, trust_level: TrustLevel[1]) }
  fab!(:topic) do
    Fabricate(:topic, category: category, user: owner, title: "Critique my image please")
  end
  fab!(:first_post) do
    Fabricate(:post, topic: topic, user: owner, raw: "Original body for critique.")
  end

  def fab_upload(name, width: 800, height: 600)
    Fabricate(:upload, user: owner, original_filename: name, width: width, height: height)
  end

  def raw_after(upload, mode: :add)
    described_class.call(topic: topic, upload: upload, user: owner, mode: mode)
    first_post.reload.raw
  end

  before do
    enable_current_plugin
    SiteSetting.revised_critique_category_ids = category.id.to_s
    SiteSetting.revised_critique_max_revisions = 5
  end

  it "labels the revision image alt as 'Revision N - filename' with dimensions intact" do
    raw = raw_after(fab_upload("sunset.jpg"))

    expect(raw).to include("![Revision 1 - sunset.jpg|800x600](")
  end

  it "increments the revision number on each added image" do
    raw_after(fab_upload("first.jpg"))
    raw = raw_after(fab_upload("second.jpg"))

    expect(raw).to include("![Revision 2 - second.jpg|800x600](")
    expect(raw).to include("![Revision 1 - first.jpg|800x600](")
  end

  it "stores the original_filename on the history entry" do
    raw_after(fab_upload("sunset.jpg"))

    history = DiscourseRevisedCritiqueImage::RevisionHistory.for(topic.reload)
    expect(history.latest["original_filename"]).to eq("sunset.jpg")
  end

  it "sanitizes characters that would break the image markup or dimension syntax" do
    raw = raw_after(fab_upload("a|b]c(d).png"))

    expect(raw).to include("![Revision 1 - a b c d .png|800x600](")
    expect(raw).not_to include("a|b]c(d).png")
  end

  it "still renders fallback dimensions when the upload has none" do
    raw = raw_after(fab_upload("nodims.jpg", width: 0, height: 0))

    expect(raw).to include("![Revision 1 - nodims.jpg|690x460](")
  end

  context "with a legacy history entry that predates original_filename" do
    def seed_history!(entry)
      topic.custom_fields[DiscourseRevisedCritiqueImage::REVISED_IMAGE_HISTORY] = [entry]
      topic.save_custom_fields(true)
    end

    it "falls back to the live Upload's filename" do
      legacy_upload = fab_upload("legacy.jpg")
      seed_history!(
        {
          "revision_number" => 1,
          "upload_id" => legacy_upload.id,
          "upload_short_url" => legacy_upload.short_url,
          "width" => 800,
          "height" => 600,
        },
      )

      raw = raw_after(fab_upload("new.jpg"))

      expect(raw).to include("![Revision 1 - legacy.jpg|800x600](#{legacy_upload.short_url})")
      expect(raw).to include("![Revision 2 - new.jpg|800x600](")
    end

    it "falls back to a bare 'Revision N' when the upload is gone" do
      seed_history!(
        {
          "revision_number" => 1,
          "upload_id" => 0,
          "upload_short_url" => "upload://legacygone.jpg",
          "width" => 800,
          "height" => 600,
        },
      )

      raw = raw_after(fab_upload("new.jpg"))

      expect(raw).to include("![Revision 1|800x600](upload://legacygone.jpg)")
    end
  end
end
