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
    # Whether the sibling plugin's namespace is loaded depends on the
    # environment: a local developer checkout has all NPN plugins
    # side-by-side, but the plugin's GitHub Actions CI clones only this
    # plugin. The compat wrapper has to work in both modes, so we
    # accept either answer here and only assert that the *value* is
    # boolean and consistent with the live `defined?` check.
    it "returns a boolean that matches whether the namespace is defined" do
      expected = defined?(::DiscourseNpnSubmissions) ? true : false
      expect(described_class.submissions_loaded?).to eq(expected)
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
