# frozen_string_literal: true

module DiscourseRevisedCritiqueImage
  # Neutralizes HTML-comment delimiters in user-supplied strings.
  #
  # Notes and captions are embedded verbatim inside the managed block, which
  # later revisions locate by scanning the post raw for HTML-comment markers
  # (e.g. `<!-- revised-critique-image:end -->`). A note or caption containing
  # such a marker would inject a premature block boundary and truncate/corrupt
  # the block on the next revision. Every marker is an HTML comment, so breaking
  # the `<!--` / `-->` delimiters means no marker can ever appear in user text.
  module MarkerSafety
    module_function

    def neutralize(str)
      str.to_s.gsub("<!--", "&lt;!--").gsub("-->", "--&gt;")
    end
  end
end
