# frozen_string_literal: true

module DiscourseRevisedCritiqueImage
  # Phase 2 read-only handoff verifier.
  #
  # Given a topic produced by discourse-npn-submissions in the
  # `project_critique` flow, decide whether the structured project
  # payload (and the in-post markers that bracket the generated image
  # block) are present, well-formed, and consistent enough that a future
  # project-revision editor could safely act on them.
  #
  # The reader is strictly read-only: it never assigns to custom_fields,
  # never calls save, and never touches post.raw. It only inspects.
  #
  # A `Result` is always returned; callers branch on `project?` and
  # `valid?` rather than on exceptions.
  class ProjectSubmissionReader
    PROJECT_SUBMISSION_TYPE = "project_critique"
    SUPPORTED_VERSION = 1
    MIN_IMAGES = 1
    MAX_IMAGES = 12

    # Each required field validates differently — see `image_well_formed?`.
    # Listed here as a documentation aid only.
    REQUIRED_IMAGE_FIELDS = %w[id position upload_id short_url alt].freeze

    Result =
      Struct.new(
        :project?,
        :valid?,
        :error_key,
        :images,
        :image_count,
        :begin_offset,
        :end_offset,
        :begin_marker,
        :end_marker,
        keyword_init: true,
      )

    def self.read(topic)
      new(topic).read
    end

    def initialize(topic)
      @topic = topic
    end

    def read
      return not_project unless project_submission_type?

      data = raw_data
      return invalid(:no_submission_data) if data.blank?
      return invalid(:wrong_type) unless data.is_a?(Hash) && data["type"] == PROJECT_SUBMISSION_TYPE
      return invalid(:wrong_version) unless data["version"].to_i == SUPPORTED_VERSION

      images = data["images"]
      return invalid(:images_not_array) unless images.is_a?(Array)
      return invalid(:image_count_out_of_range) if images.size < MIN_IMAGES
      return invalid(:image_count_out_of_range) if images.size > MAX_IMAGES
      return invalid(:image_missing_fields) unless all_images_well_formed?(images)

      first_post = @topic.first_post
      return invalid(:missing_first_post) if first_post.blank?

      begin_offset = first_post.raw.to_s.index(begin_marker)
      end_offset = first_post.raw.to_s.index(end_marker)
      return invalid(:markers_missing) if begin_offset.nil? || end_offset.nil?
      return invalid(:markers_reversed) if end_offset <= begin_offset

      Result.new(
        project?: true,
        valid?: true,
        error_key: nil,
        images: images.map { |img| normalize_image(img) },
        image_count: images.size,
        begin_offset: begin_offset,
        end_offset: end_offset,
        begin_marker: begin_marker,
        end_marker: end_marker,
      )
    end

    private

    def project_submission_type?
      @topic.custom_fields[SubmissionsCompat.submission_type_key].to_s == PROJECT_SUBMISSION_TYPE
    end

    def raw_data
      @topic.custom_fields[SubmissionsCompat.project_data_key]
    end

    # Every image must carry the keys downstream code will rely on. We
    # require upload_id (positive integer) because the submissions plugin
    # always writes Upload#id; treating it as optional would let a
    # malformed payload propagate further into the editor before failing.
    # Position must be a positive integer (the submissions plugin emits
    # 1-indexed positions). String fields must be non-blank.
    def all_images_well_formed?(images)
      images.all? { |img| image_well_formed?(img) }
    end

    def image_well_formed?(img)
      return false unless img.is_a?(Hash)
      return false unless img["id"].is_a?(String) && img["id"].present?
      return false unless positive_integer?(img["position"])
      return false unless positive_integer?(img["upload_id"])
      return false unless img["short_url"].is_a?(String) && img["short_url"].present?
      return false unless img["alt"].is_a?(String) && img["alt"].present?
      true
    end

    def positive_integer?(value)
      value.is_a?(Integer) && value.positive?
    end

    # Project images are exposed to the rest of the plugin only via
    # this normalized shape. We coerce caption to a String (the
    # submissions plugin always writes one, but the reader shouldn't
    # depend on the producer being well-behaved). Everything else is
    # passed through untouched — the editor in a later phase decides
    # what to do with it.
    def normalize_image(img)
      {
        "id" => img["id"],
        "position" => img["position"],
        "upload_id" => img["upload_id"],
        "short_url" => img["short_url"],
        "caption" => img["caption"].to_s,
        "alt" => img["alt"],
      }
    end

    def begin_marker
      @begin_marker ||= SubmissionsCompat.block_begin
    end

    def end_marker
      @end_marker ||= SubmissionsCompat.block_end
    end

    def not_project
      Result.new(
        project?: false,
        valid?: false,
        error_key: nil,
        images: [],
        image_count: 0,
        begin_offset: nil,
        end_offset: nil,
        begin_marker: begin_marker,
        end_marker: end_marker,
      )
    end

    def invalid(error_key)
      Result.new(
        project?: true,
        valid?: false,
        error_key: error_key,
        images: [],
        image_count: 0,
        begin_offset: nil,
        end_offset: nil,
        begin_marker: begin_marker,
        end_marker: end_marker,
      )
    end
  end
end
