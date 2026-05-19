# frozen_string_literal: true

describe "Revised critique image flow" do
  fab!(:category)
  fab!(:owner) { Fabricate(:user, trust_level: TrustLevel[1]) }
  fab!(:other_user) { Fabricate(:user, trust_level: TrustLevel[1]) }
  fab!(:topic) { Fabricate(:topic, category: category, user: owner) }
  fab!(:first_post) do
    Fabricate(:post, topic: topic, user: owner, raw: "Original image post body.")
  end

  before do
    enable_current_plugin
    SiteSetting.revised_critique_category_id = category.id
    SiteSetting.revised_critique_max_revisions = 2
  end

  it "shows one primary button before any revision exists" do
    Fabricate(:post, topic: topic, user: other_user, raw: "Feedback comment.")
    sign_in(owner)

    visit "/t/#{topic.slug}/#{topic.id}"
    expect(page).to have_css(".revised-image-banner[data-revised-image-banner-state='first']")
    expect(page).to have_css(".revised-image-banner__primary")
    expect(page).to have_no_css(".revised-image-banner__secondary")
  end

  it "shows replace and add-another buttons when below max" do
    Fabricate(:post, topic: topic, user: other_user, raw: "Feedback.")
    DiscourseRevisedCritiqueImage::RevisionHistory.for(topic).add!(
      upload: Fabricate(:upload, user: owner, original_filename: "r1.png", width: 800, height: 600),
      user: owner,
      note: "first",
    )
    sign_in(owner)

    visit "/t/#{topic.slug}/#{topic.id}"
    expect(page).to have_css(".revised-image-banner[data-revised-image-banner-state='mixed']")
    expect(page).to have_css(".revised-image-banner__primary")
    expect(page).to have_css(".revised-image-banner__secondary")
  end

  it "shows only the replace button at max revisions" do
    Fabricate(:post, topic: topic, user: other_user, raw: "Feedback.")
    history = DiscourseRevisedCritiqueImage::RevisionHistory.for(topic)
    history.add!(
      upload: Fabricate(:upload, user: owner, original_filename: "r1.png", width: 800, height: 600),
      user: owner,
      note: "first",
    )
    history.add!(
      upload: Fabricate(:upload, user: owner, original_filename: "r2.png", width: 800, height: 600),
      user: owner,
      note: "second",
    )
    sign_in(owner)

    visit "/t/#{topic.slug}/#{topic.id}"
    expect(page).to have_css(".revised-image-banner[data-revised-image-banner-state='atMax']")
    expect(page).to have_css(".revised-image-banner__primary")
    expect(page).to have_no_css(".revised-image-banner__secondary")
  end

  it "does not show the banner to non-owners" do
    Fabricate(:post, topic: topic, user: other_user, raw: "Feedback.")
    sign_in(other_user)

    visit "/t/#{topic.slug}/#{topic.id}"
    expect(page).to have_no_css(".revised-image-banner")
  end
end
