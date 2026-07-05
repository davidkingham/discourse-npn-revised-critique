# Discourse compatibility surface

A focused map of where this plugin reaches into Discourse core, what's
most likely to drift during a core update, and how to verify the user-
facing flows still work before rolling a forum forward.

For the file-by-file table of every fragile call site (with mitigation
notes), see the **Fragile integration points** section of
`MAINTENANCE.md`. This document is the higher-level companion: what to
worry about, and what to actually click through after a core update.

Target Discourse version: `main` (a.k.a. "latest" / tests-passed). CI
does not test against stable — see `.github/workflows/discourse-plugin.yml`.

---

## What the plugin does

It lets the original poster of an image-critique topic (in a configured
category) publish a revised version of their image after receiving
feedback, without leaving the topic.

When the OP submits a revision through the banner-and-modal UI:

1. A new entry is appended to a JSON revision history stored on the
   topic's custom fields, or — in `replace_latest` mode — the most
   recent entry is mutated in place.
2. The first post's markdown is rewritten between fenced HTML comment
   markers so every revision is shown (latest first), with optional
   per-revision notes.
3. The topic title optionally gets a configurable marker appended
   (e.g. `(+revised)`), but only if the result fits inside
   `max_topic_title_length`.
4. Denormalised "latest revision" custom fields are kept in sync with
   the last history entry so legacy/external consumers can read the
   current state without parsing the JSON.
5. An NPN-namespaced snapshot (`npn_revision_count`,
   `npn_latest_revision_upload_id`, `npn_latest_revision_image_url`,
   `npn_revision_images`, `npn_critique_image_version_schema`) is
   refreshed for the sibling `discourse-npn-critique-reply` plugin.
6. Optionally, a notice reply is posted in-thread by a configured user
   (defaults to `system`).
7. The frontend router refreshes so the new content shows.

Eligibility is computed both server-side (controller + service) and
serialised for the client via `TopicViewSerializer` (the `can_*`
booleans drive whether the banner appears, and which buttons it shows).

Gates: plugin enabled, user is topic owner, user not suspended, topic
is in the configured category, topic is not closed / archived /
deleted, first post is editable per `Guardian#can_edit?`, optionally
at least one reply from another user exists, and (for `add`) the
revision count is below `revised_critique_max_revisions`.

A per-user rate limit of 6 revisions per hour applies to non-staff
(`RateLimiter` with key `"revised-critique-image"`).

---

## Discourse core areas this plugin depends on

Grouped by likely failure mode rather than file. Each item names the
exact symbol used so a `git log -p` in core finds the change.

### Plugin extension points (lowest churn)

- `enabled_site_setting :revised_critique_enabled` in `plugin.rb`.
- `register_asset` for SCSS.
- `register_svg_icon` for `image`, `arrows-rotate`, `plus`.
- `Topic.register_custom_field_type` for the `revised_image_*` and
  `npn_*` fields (declared in `plugin.rb`).
- `TopicList.preloaded_custom_fields << ...` to avoid N+1 reads on
  topic lists.
- A mounted engine at `/revised-critique-image` via
  `Discourse::Application.routes.append`.

### Server-side Ruby APIs (medium churn)

- `TopicViewSerializer.prepend …Extension` to add five attributes:
  `revised_critique_image`, `revised_critique_image_revision_count`,
  `revised_critique_image_max_revisions`, `can_add_revised_critique_image`,
  `can_replace_latest_revised_critique_image`.
- `PostRevisor.new(first_post, topic).revise!` called with
  `skip_validations: true`, `bypass_bump: true`, `skip_revision: false`
  and fields `{ raw:, title: }`.
- `PostCreator.create!` (for the optional notice reply) with
  `skip_validations: true`.
- `Upload` model accessors: `id`, `short_url`, `width`, `height`,
  `extension`, `url`.
- `FileHelper.is_supported_image?(filename_with_ext)` for the
  server-side raster-image check (SVG is explicitly rejected).
- `Guardian#can_see?(topic)` and `Guardian#can_edit?(first_post)` for
  authorisation (controller and `Eligibility`).
- `RateLimiter.new(user, key, max, period).performed!` and the
  `RateLimiter::LimitExceeded` exception.
- `Discourse.system_user`, `Discourse::NotFound`.
- `Topic#first_post`, `Topic#custom_fields`, `Topic#save_custom_fields`,
  `Topic#category_id`, `Topic#closed?`, `Topic#archived?`,
  `Topic#deleted_at`, `Topic#title`.
- `Post` query: `Post.where(topic_id:, deleted_at: nil)` filtered by
  `post_number > 1` and `user_id <> ?` (the "another user replied"
  check).
- Implicit secure-upload contract: a fresh upload referenced for the
  first time from the first post inherits `access_control_post_id`
  from `app/models/concerns/has_post_upload_references.rb`.

### Frontend JS imports (highest churn — recently moved)

- `discourse/lib/api` → `apiInitializer`, `api.renderInOutlet`.
- Plugin outlet name: **`topic-above-posts`**. Outlet args expected to
  expose `model` (the topic).
- `discourse/ui-kit/d-button` (banner + modal).
- `discourse/ui-kit/d-modal` and `discourse/ui-kit/d-modal-cancel`
  (modal frame).
- `discourse/components/uppy-image-uploader` with args
  `@id`, `@type="revised_critique_image"`, `@imageUrl`,
  `@onUploadDone`, `@onUploadDeleted`. The `onUploadDone` callback
  expects an object with `.url` and `.id`.
- `discourse/lib/ajax` + `discourse/lib/ajax-error` for the POST and
  for surfacing error JSON.
- `discourse-i18n` (`i18n` helper).
- Standard Ember imports (`@glimmer/component`, `@glimmer/tracking`,
  `@ember/modifier`, `@ember/object`, `@ember/service`) — these are
  stable and unlikely to be the source of breakage.
- Router service: `this.router.refresh()` after a successful submit.

### Topic body markdown contract (self-contained, but visible to users)

The first-post rewrite is bracketed by `<!-- revised-critique-image:begin -->`
and `<!-- revised-critique-image:end -->`. Anything inside is owned by
the plugin and will be regenerated on the next revision. Anything
outside is preserved, with the original body re-rendered under an
`## Original` heading. If a future Discourse cooker change strips
HTML comments or sanitises them differently, the strip-and-rebuild
logic will start treating every revision as fresh (no deduping).

---

## Most likely to break during a core update

Ranked roughly by how often the underlying surface churns upstream and
how severe the user-visible failure is.

### 1. `ui-kit/` import paths (very recent, will move again)

`DButton`, `DModal`, and `DModalCancel` moved from
`discourse/components/...` to `discourse/ui-kit/...` on 2026-05-11.
The old paths still work on `main` via the shim layer in
`app/ui-kit-shims.js`, but a future cleanup could remove the shims, or
more components could be folded into `ui-kit/` and renamed at the
same time.

**Symptom**: bare-white topic page; browser console shows
`Could not find module 'discourse/ui-kit/d-…'`.
**Detection**: any system spec in `spec/system/` will fail before the
banner renders, with that same error in the captured JS log.

### 2. `topic-above-posts` plugin outlet

The single insertion point for the banner. Discourse renames or
relocates outlets occasionally during topic-page refactors.

**Symptom**: plugin runs, no JS errors, but the banner is invisible
even on a topic where eligibility is `true`.
**Detection**: hit `/t/<slug>/<id>.json` and confirm
`can_add_revised_critique_image` (or `_replace_latest_`) is `true`;
if so, the JS side isn't mounting — the outlet is gone or renamed.

### 3. `UppyImageUploader` argument shape

The modal hands off the entire upload UX. Discourse periodically
refactors uploader internals — the args we pass (`@onUploadDone`,
`@onUploadDeleted`, `@type`, `@imageUrl`) are the most likely to
change shape.

**Symptom**: clicking the button opens the modal but uploads silently
fail, or `upload_id` arrives `null` at the server, or a TypeError in
console.
**Detection**: dev tools network tab shows no POST to
`/revised-critique-image/topics/.../revisions`, or it shows one with
`upload_id: null` returning 404 `missing_upload`.

### 4. `PostRevisor.revise!` flag set

The plugin passes `skip_validations`, `bypass_bump`, `skip_revision`,
and rewrites both `:raw` and `:title`. Any of those names being
renamed (or `skip_validations` being narrowed) will break revisions
silently — the call returns `false` and the controller surfaces a
generic `revision_failed`.

**Symptom**: submitting a revision returns a 422 with
`error_key: "revision_failed"`, but no other diagnostic.
**Detection**: server log will show the underlying `ActiveRecord`
validation error — typically "Body is too short" if the OP's raw is
short and `skip_validations` no longer applies.

### 5. `TopicViewSerializer` attribute API

We `prepend` and call `base.attributes :foo, :bar, …`. Discourse has
been moving toward contract/strict-typed serializers; if that machinery
replaces the `attributes` DSL, the prepend either does nothing or
raises at boot.

**Symptom**: the banner never appears for anyone — the `can_*` booleans
are missing from the topic JSON, so the JS treats every topic as
ineligible.
**Detection**: in `/t/<id>.json`, search for `can_add_revised_critique_image`.
If absent, the serializer extension isn't being applied.

### 6. `Upload#short_url` and secure-upload contract

The revision markdown uses `![…](#{entry["upload_short_url"]})` so
Discourse cooks the image and applies access control. The plugin
relies on the rule that a fresh upload's `access_control_post_id`
is set when first referenced from a post. If this contract changes,
secure uploads may 403 for other users even though the upload appears
in the markdown.

**Symptom**: revisions appear blank for other users (broken image
icons), but show fine for the OP.

### 7. `RateLimiter` and `FileHelper.is_supported_image?`

`RateLimiter.new(user, key, max, period).performed!` is a stable
public API, but the constructor signature has been touched before.
`FileHelper.is_supported_image?` currently takes a filename-with-
extension; if it ever switches to MIME type or to taking the `Upload`
directly, the controller's server-side check will silently pass or
fail on the wrong inputs.

**Symptom (rate limiter)**: the controller's rescue clause stops
firing → 500s instead of 429s under load.
**Symptom (file helper)**: SVG or other non-image uploads start
sneaking through, or all uploads start being rejected.

### 8. `Guardian#can_edit?` gating

`Eligibility` and the controller both call `Guardian#can_edit?` on
the first post. New core gates (e.g. silenced groups, locked posts,
new compliance gates) are inherited automatically — usually fine —
but a gate change could quietly tighten the policy and make the
banner disappear for users who used to see it.

**Symptom**: the banner stops showing for non-staff OPs even though
nothing in this plugin changed.

---

## Manual regression checklist (run on staging before promoting to prod)

Set up: a staging forum with this plugin installed, sibling NPN
plugins disabled (so test coverage isolates this plugin's surface),
and a category configured in `revised_critique_category_ids`. Have
two test accounts ready: `op_user` and `feedback_user`. Both at
TL1+.

Each checkbox below maps to a concrete observable behavior in the
code. Run through them top-to-bottom — most failures will surface
before you get halfway.

### Banner visibility

- [ ] As `op_user`, create a topic with an image in the configured
      category. **Without** any reply from another user yet, the
      banner does **not** appear (gated by
      `revised_critique_require_reply_from_other_user`).
- [ ] As `feedback_user`, post any reply. Reload as `op_user`. Banner
      appears, state `"first"`, one primary button labelled with
      `revised_critique_button_label` (or its i18n default).
- [ ] As an anonymous viewer, the banner does **not** appear (no
      `can_*` booleans for guests).
- [ ] As `feedback_user` (non-OP), the banner does **not** appear.
- [ ] Move the topic to a different category. Banner disappears.
      Move it back; banner returns.
- [ ] Close the topic. Banner disappears. Re-open; banner returns.
- [ ] Archive the topic. Banner disappears. Un-archive; banner
      returns.

### First revision (add mode)

- [ ] Click the primary button. Modal opens. Title reads
      "Add your revised version" (the `title_add_first` i18n key).
- [ ] Upload a PNG/JPG. Image preview appears.
- [ ] Type a note. Counter updates; once you exceed
      `revised_critique_note_max_length`, counter turns red and
      submit is disabled.
- [ ] Trim the note back under the limit. Submit becomes enabled.
- [ ] Submit. Modal closes, page refreshes (via `router.refresh()`).
- [ ] First post body now shows a "Revised Version" section above an
      "Original" section, with the revised image and the note under
      a "What changed" line.
- [ ] Topic title now ends in `(+revised)` (unless the resulting
      title would exceed `max_topic_title_length`, in which case it
      should be unchanged).
- [ ] In `/t/<id>.json`:
      `revised_critique_image_revision_count == 1`,
      `revised_critique_image.upload_id == <new id>`,
      `can_add_revised_critique_image == true`
      (assuming `revised_critique_max_revisions > 1`),
      `can_replace_latest_revised_critique_image == true`.

### Second revision (mixed state)

- [ ] Banner now shows two buttons: a primary
      "Replace latest" (icon `arrows-rotate`) and a secondary
      "Add another" (icon `plus`). Message comes from
      `can_replace_or_add_message`.
- [ ] Click "Add another". Modal title reads
      "Add another revised version" (`title_add_another`).
- [ ] Submit a second upload. First post markdown now shows two
      revisions, **latest first**, both within the markers.
      `revision_number` increments to 2.

### Replace latest

- [ ] Click "Replace latest". Modal title reads
      "Replace latest revised version" (`title_replace_latest`)
      and shows the `replace_helper` blurb.
- [ ] Submit a new upload with no note. The latest revision's
      `upload_id` updates, `note` clears, but `revision_number`
      stays the same (it's a mutation, not an append).
- [ ] In `/t/<id>.json`: `revised_critique_image_revision_count`
      did **not** increase. `revised_critique_image.updated_at`
      changed but `added_at` did not.

### Max-revision (atMax) state

- [ ] Set `revised_critique_max_revisions = 2`. Reload the topic
      (which now has 2 revisions). Banner shows only the
      "Replace latest" button. Message comes from
      `at_max_message`. No "Add another" button.
- [ ] In `/t/<id>.json`:
      `can_add_revised_critique_image == false`,
      `can_replace_latest_revised_critique_image == true`.

### Server-side validation

- [ ] In dev tools, manually POST to
      `/revised-critique-image/topics/<id>/revisions.json` with an
      SVG upload's id. Response: 422,
      `error_key: "invalid_upload"`.
- [ ] POST with a `note` longer than the configured max. Response:
      422, `error_key: "note_too_long"`.
- [ ] POST with a non-existent `upload_id`. Response: 404,
      `error_key: "missing_upload"`.
- [ ] POST with `mode: "wat"`. Response: 422,
      `error_key: "invalid_mode"`.
- [ ] As a logged-out client, POST the endpoint. Response: 403
      (the `ensure_logged_in` `before_action`).
- [ ] As `feedback_user` (non-owner), POST the endpoint. Response:
      422, `error_key: "not_owner"`.

### Rate limiting

- [ ] As a **non-staff** `op_user`, submit 6 revisions back-to-back
      (use `replace_latest` repeatedly so eligibility holds). The
      7th returns 429 with `error_key: "rate_limited"`.
- [ ] As an admin, the 7th call succeeds (staff bypass in
      `apply_rate_limit!`).

### NPN metadata snapshot

- [ ] After any successful revision, in the Rails console:
      ```ruby
      t = Topic.find(<id>)
      t.custom_fields["npn_revision_count"]            # integer
      t.custom_fields["npn_latest_revision_upload_id"] # integer
      t.custom_fields["npn_latest_revision_image_url"] # string
      t.custom_fields["npn_revision_images"]           # Array of Hashes
      t.custom_fields["npn_critique_image_version_schema"]  # 1
      ```
- [ ] Pre-set `t.custom_fields["npn_original_*"]` values, save, then
      submit a revision. The `npn_original_*` values are untouched
      after the revision lands (this plugin only writes the
      revision side).
- [ ] Manually corrupt `npn_revision_images` to a non-array (e.g.
      `"junk"`) and save. Submit another revision. The field
      self-heals back to a valid array on the next write.

### Optional notice reply

- [ ] Enable `revised_critique_add_notice_reply`. Submit a revision.
      A new post appears in the topic, posted by `system` (or the
      configured username if set), with the `notice_reply` i18n
      text. The post is created with `skip_validations: true`
      (so its body length is unconstrained).
- [ ] Disable `revised_critique_add_notice_reply`. Submit a
      revision. No extra reply is posted.

### Legacy backfill (only matters if you have v1.2 topics)

- [ ] On a v1.2-era topic that has only the scalar
      `revised_image_upload_id` set (no JSON history), submitting
      a revision should treat the existing scalar as Revision 1 and
      append the new one as Revision 2 (see
      `RevisionHistory#load_entries`).

### Final sanity

- [ ] Run `bin/rspec plugins/discourse-npn-revised-critique/spec/`
      against the target Discourse ref. All examples pass.
- [ ] Re-cook the topic (admin → re-cook) and confirm the revision
      markdown re-renders identically (the markers and image syntax
      survive cook → uncook → cook).
