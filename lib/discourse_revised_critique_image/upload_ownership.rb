# frozen_string_literal: true

module DiscourseRevisedCritiqueImage
  # Whether an upload may be used by a given user in a revision.
  #
  # Upload ids are sequential and enumerable; without this check an eligible
  # OP could pass any integer `upload_id` and have the plugin resolve it to its
  # unguessable short_url and embed it in their public post — surfacing images
  # from other users' PMs or secure categories. Mirrors the ownership check in
  # discourse-npn-submissions: the user must have uploaded the file, or a
  # UserUpload join row must record that they re-uploaded the same bytes.
  module UploadOwnership
    module_function

    def accessible?(user, upload)
      return false if user.blank? || upload.blank?
      return true if upload.user_id == user.id

      UserUpload.exists?(upload_id: upload.id, user_id: user.id)
    end
  end
end
