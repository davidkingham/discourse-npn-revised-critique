# frozen_string_literal: true

describe DiscourseRevisedCritiqueImage::SubmissionsCompat do
  describe "constants resolution" do
    it "returns the canonical project data key" do
      expect(described_class.project_data_key).to eq("npn_project_submission_data")
    end

    it "returns the canonical begin marker" do
      expect(described_class.block_begin).to eq("<!-- npn-project-submission:begin -->")
    end

    it "returns the canonical end marker" do
      expect(described_class.block_end).to eq("<!-- npn-project-submission:end -->")
    end

    it "returns the canonical submission_type key" do
      expect(described_class.submission_type_key).to eq("npn_submission_type")
    end
  end

  describe "submissions_loaded?" do
    it "returns true when the sibling plugin's namespace is defined" do
      # In CI we run with all plugins loaded, so DiscourseNpnSubmissions
      # will be present. If a future environment runs without it, this
      # spec is the canary that the fallback path needs verification.
      expect(described_class.submissions_loaded?).to eq(true)
    end
  end

  describe "agreement with sibling plugin constants" do
    it "agrees with DiscourseNpnSubmissions::TopicMetadata::PROJECT_SUBMISSION_DATA_KEY" do
      skip "submissions plugin not loaded" unless described_class.submissions_loaded?
      expect(described_class.project_data_key).to eq(
        DiscourseNpnSubmissions::TopicMetadata::PROJECT_SUBMISSION_DATA_KEY,
      )
    end

    it "agrees with DiscourseNpnSubmissions::ProjectPostBuilder markers" do
      skip "submissions plugin not loaded" unless described_class.submissions_loaded?
      expect(described_class.block_begin).to eq(
        DiscourseNpnSubmissions::ProjectPostBuilder::PROJECT_BLOCK_BEGIN,
      )
      expect(described_class.block_end).to eq(
        DiscourseNpnSubmissions::ProjectPostBuilder::PROJECT_BLOCK_END,
      )
    end
  end
end
