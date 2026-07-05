# frozen_string_literal: true

describe DiscourseRevisedCritiqueImage::RevisionsController do
  fab!(:category)
  fab!(:owner) { Fabricate(:user, trust_level: TrustLevel[1]) }
  fab!(:other_user) { Fabricate(:user, trust_level: TrustLevel[1]) }
  fab!(:topic) do
    Fabricate(:topic, category: category, user: owner, title: "Critique my image please")
  end
  fab!(:first_post) do
    Fabricate(:post, topic: topic, user: owner, raw: "Original critique image post.")
  end

  let(:endpoint) { "/revised-critique-image/topics/#{topic.id}/revisions.json" }

  def fab_upload(filename: "rev.png", width: 800, height: 600)
    Fabricate(:upload, user: owner, original_filename: filename, width: width, height: height)
  end

  before do
    enable_current_plugin
    SiteSetting.revised_critique_category_ids = category.id.to_s
    SiteSetting.revised_critique_max_revisions = 3
  end

  context "as the OP" do
    before { sign_in(owner) }

    it "rejects when there are no replies from other users" do
      post endpoint, params: { upload_id: fab_upload.id }

      expect(response.status).to eq(422)
      expect(response.parsed_body["error_key"]).to eq("no_replies")
    end

    context "with a reply from another user" do
      before { Fabricate(:post, topic: topic, user: other_user, raw: "Some feedback for you.") }

      describe "add (first revision)" do
        let(:upload) { fab_upload }

        it "creates Revision 1, appends the title marker, and renders the block" do
          post endpoint, params: { upload_id: upload.id, note: "  Pulled back highlights.  " }

          expect(response.status).to eq(200)
          topic.reload
          expect(topic.title).to eq("Critique my image please (+revised)")

          history = DiscourseRevisedCritiqueImage::RevisionHistory.for(topic)
          expect(history.count).to eq(1)
          latest = history.latest
          expect(latest["revision_number"]).to eq(1)
          expect(latest["upload_id"]).to eq(upload.id)
          expect(latest["note"]).to eq("Pulled back highlights.")
          expect(latest["user_id"]).to eq(owner.id)

          raw = first_post.reload.raw
          expect(raw).to include("## Revised Version")
          expect(raw).to include("Revision 1 (latest)")
          expect(raw).to include(upload.short_url)
          expect(raw).to include("**What changed:** Pulled back highlights.")
          expect(raw).to include("## Original Version")
        end

        it "rejects an over-length note" do
          SiteSetting.revised_critique_note_max_length = 10
          post endpoint, params: { upload_id: upload.id, note: "x" * 50 }
          expect(response.status).to eq(422)
          expect(response.parsed_body["error_key"]).to eq("note_too_long")
        end

        it "rejects an upload the requester does not own (IDOR)" do
          foreign = Fabricate(:upload, user: other_user, original_filename: "theirs.png")

          expect { post endpoint, params: { upload_id: foreign.id } }.not_to change {
            DiscourseRevisedCritiqueImage::RevisionHistory.for(topic).count
          }

          expect(response.status).to eq(422)
          expect(response.parsed_body["error_key"]).to eq("invalid_upload")
        end

        it "accepts an upload the requester re-uploaded (UserUpload join row)" do
          foreign = Fabricate(:upload, user: other_user, original_filename: "shared.png")
          UserUpload.create!(upload_id: foreign.id, user_id: owner.id)

          post endpoint, params: { upload_id: foreign.id }
          expect(response.status).to eq(200)
        end

        it "neutralizes an end-marker injected via the note so the block survives re-revision" do
          marker = DiscourseRevisedCritiqueImage::RevisionAdder::END_MARKER
          post endpoint, params: { upload_id: upload.id, note: "sneaky #{marker} tail" }
          expect(response.status).to eq(200)

          # Second revision must still find exactly one intact block to strip.
          r2 = fab_upload(filename: "r2.png", width: 640, height: 480)
          post endpoint, params: { upload_id: r2.id, note: "second" }
          expect(response.status).to eq(200)

          raw = first_post.reload.raw
          expect(raw.scan(marker).length).to eq(1)
          expect(raw).to include("Revision 2 (latest)")
          expect(raw).to include("Revision 1")
        end
      end

      describe "add (subsequent revisions)" do
        before do
          post endpoint, params: { upload_id: fab_upload(filename: "r1.png").id, note: "first" }
          expect(response.status).to eq(200)
        end

        it "creates Revision 2 while preserving Revision 1" do
          r2 = fab_upload(filename: "r2.png", width: 700, height: 500)
          post endpoint, params: { upload_id: r2.id, note: "second" }

          expect(response.status).to eq(200)
          history = DiscourseRevisedCritiqueImage::RevisionHistory.for(topic.reload)
          expect(history.count).to eq(2)
          expect(history.entries.map { |e| e["revision_number"] }).to eq([1, 2])
          expect(history.latest["upload_id"]).to eq(r2.id)

          raw = first_post.reload.raw
          expect(raw).to include("Revision 2 (latest)")
          expect(raw).to include("Revision 1")
          expect(raw).to include(r2.short_url)
        end

        it "does not duplicate the title marker on subsequent adds" do
          post endpoint, params: { upload_id: fab_upload(filename: "r2.png").id }
          expect(topic.reload.title).to eq("Critique my image please (+revised)")

          post endpoint, params: { upload_id: fab_upload(filename: "r3.png").id }
          expect(topic.reload.title).to eq("Critique my image please (+revised)")
        end

        it "rejects add when at max revisions" do
          SiteSetting.revised_critique_max_revisions = 1

          post endpoint, params: { upload_id: fab_upload(filename: "r2.png").id }

          expect(response.status).to eq(422)
          expect(response.parsed_body["error_key"]).to eq("max_revisions_reached")
        end
      end

      describe "replace_latest" do
        it "is rejected when no revisions exist yet" do
          post endpoint, params: { upload_id: fab_upload.id, mode: "replace_latest" }
          expect(response.status).to eq(422)
          expect(response.parsed_body["error_key"]).to eq("no_revision_to_replace")
        end

        context "after a first revision" do
          let!(:initial_upload) { fab_upload(filename: "r1.png") }

          before do
            post endpoint, params: { upload_id: initial_upload.id, note: "first" }
            expect(response.status).to eq(200)
          end

          it "replaces only the latest entry, keeping the revision number" do
            replacement = fab_upload(filename: "r1b.png", width: 700, height: 500)
            post endpoint,
                 params: {
                   upload_id: replacement.id,
                   note: "corrected",
                   mode: "replace_latest",
                 }

            expect(response.status).to eq(200)
            history = DiscourseRevisedCritiqueImage::RevisionHistory.for(topic.reload)
            expect(history.count).to eq(1)
            expect(history.latest["revision_number"]).to eq(1)
            expect(history.latest["upload_id"]).to eq(replacement.id)
            expect(history.latest["note"]).to eq("corrected")

            raw = first_post.reload.raw
            expect(raw).to include(replacement.short_url)
            expect(raw).not_to include(initial_upload.short_url)
            expect(raw).not_to include("first")
          end

          it "replaces only the latest of multiple revisions" do
            r2 = fab_upload(filename: "r2.png")
            post endpoint, params: { upload_id: r2.id, note: "second" }
            expect(response.status).to eq(200)

            r2b = fab_upload(filename: "r2b.png")
            post endpoint, params: { upload_id: r2b.id, note: "fixed", mode: "replace_latest" }
            expect(response.status).to eq(200)

            history = DiscourseRevisedCritiqueImage::RevisionHistory.for(topic.reload)
            expect(history.count).to eq(2)
            expect(history.entries[0]["upload_id"]).to eq(initial_upload.id)
            expect(history.entries[1]["upload_id"]).to eq(r2b.id)
            expect(history.entries[1]["revision_number"]).to eq(2)
          end

          it "is allowed when at max revisions" do
            SiteSetting.revised_critique_max_revisions = 1
            replacement = fab_upload(filename: "r1b.png")

            post endpoint, params: { upload_id: replacement.id, mode: "replace_latest" }

            expect(response.status).to eq(200)
            history = DiscourseRevisedCritiqueImage::RevisionHistory.for(topic.reload)
            expect(history.count).to eq(1)
            expect(history.latest["upload_id"]).to eq(replacement.id)
          end
        end
      end

      it "rejects unknown modes" do
        post endpoint, params: { upload_id: fab_upload.id, mode: "delete_everything" }
        expect(response.status).to eq(422)
        expect(response.parsed_body["error_key"]).to eq("invalid_mode")
      end

      it "rejects when the topic is in another category" do
        topic.update!(category: Fabricate(:category))
        post endpoint, params: { upload_id: fab_upload.id }
        expect(response.status).to eq(422)
        expect(response.parsed_body["error_key"]).to eq("not_in_category")
      end
    end
  end

  context "as a non-OP user" do
    before do
      Fabricate(:post, topic: topic, user: other_user, raw: "Feedback")
      sign_in(other_user)
    end

    it "is rejected on add" do
      post endpoint, params: { upload_id: fab_upload.id }
      expect(response.status).to eq(422)
      expect(response.parsed_body["error_key"]).to eq("not_owner")
    end

    it "is rejected on replace_latest" do
      post endpoint, params: { upload_id: fab_upload.id, mode: "replace_latest" }
      expect(response.status).to eq(422)
      expect(response.parsed_body["error_key"]).to eq("not_owner")
    end
  end

  context "as an anonymous user" do
    it "is rejected" do
      post endpoint, params: { upload_id: fab_upload.id }
      expect(response.status).to eq(403)
    end
  end

  context "when the topic is a project critique submission" do
    let(:submission_type_key) do
      DiscourseRevisedCritiqueImage::SubmissionsCompat.submission_type_key
    end
    let(:data_key) { DiscourseRevisedCritiqueImage::SubmissionsCompat.project_data_key }
    let(:begin_marker) { DiscourseRevisedCritiqueImage::SubmissionsCompat.block_begin }
    let(:end_marker) { DiscourseRevisedCritiqueImage::SubmissionsCompat.block_end }

    before do
      Fabricate(:post, topic: topic, user: other_user, raw: "Feedback")
      sign_in(owner)

      topic.custom_fields[submission_type_key] = "project_critique"
      topic.custom_fields[data_key] = {
        "type" => "project_critique",
        "version" => 1,
        "images" => [
          {
            "id" => "a1b2c3d4e5f60718",
            "position" => 1,
            "upload_id" => 42,
            "short_url" => "upload://abc.jpeg",
            "caption" => "",
            "alt" => "Image 1",
          },
        ],
      }
      topic.save_custom_fields(true)
      first_post.update!(raw: "#{begin_marker}\n\nstuff\n\n#{end_marker}")
    end

    it "rejects add with project_topic_unsupported" do
      post endpoint, params: { upload_id: fab_upload.id }
      expect(response.status).to eq(422)
      expect(response.parsed_body["error_key"]).to eq("project_topic_unsupported")
    end

    it "rejects replace_latest with project_topic_unsupported" do
      post endpoint, params: { upload_id: fab_upload.id, mode: "replace_latest" }
      expect(response.status).to eq(422)
      expect(response.parsed_body["error_key"]).to eq("project_topic_unsupported")
    end

    it "does not write any revision history" do
      post endpoint, params: { upload_id: fab_upload.id }
      history = DiscourseRevisedCritiqueImage::RevisionHistory.for(topic.reload)
      expect(history.count).to eq(0)
    end

    it "does not mutate the first post raw" do
      before_raw = first_post.reload.raw
      post endpoint, params: { upload_id: fab_upload.id }
      expect(first_post.reload.raw).to eq(before_raw)
    end

    it "still rejects when the project payload is malformed" do
      # Eligibility must not crash on bad project data; it should still
      # treat the topic as a project topic (because npn_submission_type
      # is set) and refuse, rather than letting single-image proceed.
      topic.custom_fields[data_key] = { "type" => "project_critique" } # missing version + images
      topic.save_custom_fields(true)

      post endpoint, params: { upload_id: fab_upload.id }
      # The reader returns project? true with valid? false; gate fires.
      expect(response.status).to eq(422)
      expect(response.parsed_body["error_key"]).to eq("project_topic_unsupported")
    end
  end

  context "with security guards" do
    before do
      Fabricate(:post, topic: topic, user: other_user, raw: "Feedback")
      sign_in(owner)
    end

    it "rejects when the topic is closed" do
      topic.update!(closed: true)
      post endpoint, params: { upload_id: fab_upload.id }
      expect(response.status).to eq(403)
      expect(response.parsed_body["error_key"]).to eq("cannot_edit_post")
    end

    it "rejects an SVG upload" do
      svg =
        Fabricate(
          :upload,
          user: owner,
          original_filename: "logo.svg",
          extension: "svg",
          width: 100,
          height: 100,
        )
      post endpoint, params: { upload_id: svg.id }
      expect(response.status).to eq(422)
      expect(response.parsed_body["error_key"]).to eq("invalid_upload")
    end

    it "rate-limits non-staff" do
      RateLimiter.enable
      freeze_time
      stub_const(DiscourseRevisedCritiqueImage::RevisionsController, :RATE_LIMIT_MAX, 1) do
        post endpoint, params: { upload_id: fab_upload(filename: "a.png").id }
        expect(response.status).to eq(200)

        post endpoint, params: { upload_id: fab_upload(filename: "b.png").id }
        expect(response.status).to eq(429)
        expect(response.parsed_body["error_key"]).to eq("rate_limited")
      end
    ensure
      RateLimiter.disable
    end
  end
end
