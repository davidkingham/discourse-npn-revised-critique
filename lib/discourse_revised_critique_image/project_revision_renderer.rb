# frozen_string_literal: true

module DiscourseRevisedCritiqueImage
  # Renders the markdown that lives BETWEEN the
  # <!-- npn-project-submission:begin --> / :end markers. Composes:
  #
  #   1. The latest project version (revision or original) shown expanded.
  #   2. Any prior revisions in [details] blocks, newest-to-oldest.
  #   3. The original submission in a final [details] block, when at least
  #      one revision exists (otherwise the original IS the latest and is
  #      rendered expanded at the top instead).
  #
  # A version that has a drawn wall picture (the photographer's hang, see
  # discourse-npn-submissions) shows that picture in place of the overview
  # grid; versions without one keep the grid.
  #
  # Each rendered version emits a "Project Overview" raw HTML grid (using
  # the same CSS classes the submissions plugin uses, so the existing
  # styling and allowlists carry over) and an "Image Sequence" markdown
  # list (so Discourse's lightbox + image optimisation work as usual).
  #
  # The renderer is pure data-in / string-out. It loads uploads once at
  # the start so the grid can render real `/uploads/` URLs (raw HTML
  # doesn't process `upload://`), but never mutates anything.
  class ProjectRevisionRenderer
    ORIGINAL_SECTION_LABEL = "Original Submission"

    def self.render(original_data:, revisions:, original_hang_image_upload_id: nil, intent: nil)
      new(
        original_data: original_data,
        revisions: revisions,
        original_hang_image_upload_id: original_hang_image_upload_id,
        intent: intent,
      ).render
    end

    def initialize(original_data:, revisions:, original_hang_image_upload_id: nil, intent: nil)
      @original_images = Array(original_data && original_data["images"])
      @revisions = Array(revisions)
      @original_hang_image_upload_id = original_hang_image_upload_id.to_i
      @intent = intent
      @uploads_by_id = preload_uploads
    end

    def render
      sections = []

      if @revisions.any?
        latest = @revisions.last
        sections << version_section(
          images: Array(latest["images"]),
          heading: nil, # expanded; no [details] wrapper
          hang_image_upload_id: latest["hang_image_upload_id"],
        )
        prior_revisions.reverse_each do |rev|
          sections << version_section(
            images: Array(rev["images"]),
            heading: label_for_revision(rev),
            hang_image_upload_id: rev["hang_image_upload_id"],
          )
        end
        if @original_images.any?
          sections << version_section(
            images: @original_images,
            heading: ORIGINAL_SECTION_LABEL,
            hang_image_upload_id: @original_hang_image_upload_id,
          )
        end
      else
        # No revisions yet: render the original expanded. This branch
        # exists for safety — adders always write the first revision
        # before calling render — but means the renderer is also usable
        # for a "preview the original" smoke test.
        sections << version_section(
          images: @original_images,
          heading: nil,
          hang_image_upload_id: @original_hang_image_upload_id,
        )
      end

      sections.compact.join("\n\n")
    end

    private

    # Revisions other than the latest one, in stored order (oldest first).
    # render walks them in reverse so the output is newest → oldest, then
    # the original last.
    def prior_revisions
      @revisions[0...-1] || []
    end

    def label_for_revision(rev)
      "Revision #{rev["revision_number"].to_i}"
    end

    def version_section(images:, heading:, hang_image_upload_id: nil)
      return nil if Array(images).empty?

      overview = hang_picture(hang_image_upload_id, images) || overview_grid(images)
      body = [overview, image_sequence(images)].compact.join("\n\n")
      if heading
        # Discourse's [details=…] supports HTML attributes only when quoted.
        # The label is content we control, so no user input reaches here,
        # but quote it anyway to keep the syntax robust against future
        # parser changes.
        "[details=\"#{heading}\"]\n#{body}\n[/details]"
      else
        body
      end
    end

    # The wall picture for a version, in the submissions plugin's markup, or
    # nil (no picture, deleted upload, or that plugin can't render it).
    def hang_picture(upload_id, images)
      upload = @uploads_by_id[upload_id.to_i]
      return nil if upload.nil?
      SubmissionsCompat.hang_markup(upload: upload, count: Array(images).size, intent: @intent)
    end

    # Raw HTML matching the submissions plugin's existing CSS allowlist
    # (npn-project-overview-*) so all rendered versions share styling.
    # Falls back to omitting cells whose Upload was deleted rather than
    # emitting a broken <img> tag.
    #
    # COUPLING: the sanitizer allowlist that lets these class attributes
    # survive cooking lives in discourse-npn-submissions' markdown-it feature
    # (and the SCSS in its stylesheet). Plugin markdown features/assets only
    # load for ENABLED plugins, so if submissions is disabled while this plugin
    # stays on, a re-cook strips the classes and the grid collapses to stacked
    # full-size images. These two plugins are effectively enable-coupled.
    def overview_grid(images)
      cells =
        images.each_with_index.flat_map do |img, index|
          label = "Image #{index + 1}"
          src = upload_url_for(img)
          next [] if src.blank?

          [
            '<div class="npn-project-overview-item">',
            %(<div class="npn-project-overview-label">#{escape_html(label)}</div>),
            '<div class="npn-project-overview-frame">',
            %(<img class="npn-project-overview-image" src="#{escape_html(src)}" alt="#{escape_html(label)}" loading="lazy">),
            "</div>",
            "</div>",
          ]
        end

      return nil if cells.empty?

      [
        "### Project Overview",
        "",
        '<div class="npn-project-overview-grid">',
        *cells,
        "</div>",
      ].join("\n")
    end

    # Markdown image list. `upload://` short URLs let Discourse swap in
    # optimized images and wire the lightbox; the **Image N** label keeps
    # the sequence aligned with the overview grid above.
    def image_sequence(images)
      blocks =
        images.each_with_index.flat_map do |img, index|
          label = "Image #{index + 1}"
          short_url = img["short_url"].to_s
          next [] if short_url.blank?

          parts = ["**#{label}**", "![#{label}](#{short_url})"]
          if img["caption"].to_s.strip.present?
            parts << "*#{MarkerSafety.neutralize(img["caption"].to_s.strip)}*"
          end
          parts
        end

      return nil if blocks.empty?

      "### Image Sequence\n\n#{blocks.join("\n\n")}"
    end

    def upload_url_for(img)
      upload = @uploads_by_id[img["upload_id"].to_i]
      upload&.url.presence
    end

    def preload_uploads
      ids = collect_upload_ids
      return {} if ids.empty?
      Upload.where(id: ids).index_by(&:id)
    end

    def collect_upload_ids
      ids = @original_images.map { |i| i["upload_id"] }
      @revisions.each do |rev|
        ids.concat(Array(rev["images"]).map { |i| i["upload_id"] })
        ids << rev["hang_image_upload_id"]
      end
      ids << @original_hang_image_upload_id
      ids.compact.map(&:to_i).uniq
    end

    def escape_html(value)
      ERB::Util.html_escape(value.to_s)
    end
  end
end
