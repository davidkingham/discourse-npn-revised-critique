import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { concat, fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { getOwner } from "@ember/owner";
import didInsert from "@ember/render-modifiers/modifiers/did-insert";
import { service } from "@ember/service";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import UppyUpload from "discourse/lib/uppy/uppy-upload";
import { eq, not } from "discourse/truth-helpers";
import DButton from "discourse/ui-kit/d-button";
import DModal from "discourse/ui-kit/d-modal";
import DModalCancel from "discourse/ui-kit/d-modal-cancel";
import { i18n } from "discourse-i18n";

const HARD_IMAGE_LIMIT = 12;

let nextLocalId = 0;
function generateLocalId() {
  nextLocalId += 1;
  return `new-${Date.now()}-${nextLocalId}`;
}

// Defensively rebuild an image entry so each card has a unique, non-blank
// id even if the persisted data was corrupted upstream. Duplicate ids on
// cards would also break Glimmer's @each key="id" reactivity.
function normalizeBaselineImages(images) {
  const seenIds = new Set();
  return (images || []).map((img) => {
    let id = img.id;
    if (!id || typeof id !== "string" || seenIds.has(id)) {
      id = generateLocalId();
    }
    seenIds.add(id);
    return { ...img, id };
  });
}

export default class ProjectRevisionEditor extends Component {
  @service router;
  @service siteSettings;

  @tracked images = [];
  @tracked note = "";
  @tracked submitting = false;
  @tracked errorMessage = null;

  // Native HTML5 drag-and-drop state. The Move up / Move down buttons
  // are the accessible primary path; drag-and-drop is a pointer
  // convenience layered on top, matching the pattern Discourse uses
  // in sidebar/section-form-link.gjs.
  @tracked dragSourceId = null;
  @tracked dragOverId = null;
  // "above" or "below" — which edge of the over-card the pointer is on,
  // so we can render the drop indicator on the right side and decide
  // insert position when the drop lands.
  @tracked dragOverPosition = null;

  // Tracks where the next successful upload should go:
  //   { kind: "add" }                 → push a new card at the end
  //   { kind: "replace", id: <cardId> } → swap the named card's upload
  // Reset to null after each upload is consumed.
  @tracked nextUploadTarget = null;

  // One shared file input + UppyUpload instance for both "Add Image"
  // and per-card "Replace Image". Multiple per-card UppyUploaders made
  // the modal noisy AND collided around UppyUpload's id-keyed appEvents
  // bus; routing every upload through a single instance is simpler and
  // matches how Discourse's composer handles inline upload buttons.
  uppyUpload = new UppyUpload(getOwner(this), {
    id: "project-revision-editor",
    type: "revised_critique_image",
    validateUploadedFilesOptions: { imagesOnly: true },
    uploadDone: (upload) => this.routeUpload(upload),
  });

  constructor() {
    super(...arguments);
    this.loadBaseline();
  }

  willDestroy() {
    super.willDestroy(...arguments);
    this.uppyUpload?.teardown?.();
  }

  get topic() {
    return this.args.model.topic;
  }

  get mode() {
    return this.args.model.mode === "replace_latest" ? "replace_latest" : "add";
  }

  get isReplaceMode() {
    return this.mode === "replace_latest";
  }

  get maxImages() {
    const cap = parseInt(
      this.siteSettings.revised_critique_max_project_images,
      10
    );
    if (Number.isNaN(cap) || cap <= 0 || cap > HARD_IMAGE_LIMIT) {
      return HARD_IMAGE_LIMIT;
    }
    return cap;
  }

  get atMaxImages() {
    return this.images.length >= this.maxImages;
  }

  get atMinImages() {
    return this.images.length <= 1;
  }

  get canSave() {
    return !this.submitting && this.images.length > 0;
  }

  // Pre-computed indices for template comparisons. Glimmer can only call
  // bare component methods from templates when they're explicitly bound
  // (e.g. with `@action`); exposing these as getters lets the template
  // use plain `eq` / comparison helpers, which is the conventional
  // Discourse pattern.
  get lastIndex() {
    return this.images.length - 1;
  }

  get title() {
    if (this.isReplaceMode) {
      return i18n(
        "discourse_revised_critique_image.project_editor.title_replace_latest"
      );
    }
    const editor = this.topic?.project_revision_editor;
    if (editor && editor.latest) {
      return i18n(
        "discourse_revised_critique_image.project_editor.title_add_another"
      );
    }
    return i18n(
      "discourse_revised_critique_image.project_editor.title_add_first"
    );
  }

  get submitLabel() {
    if (this.submitting) {
      return i18n("discourse_revised_critique_image.project_editor.submitting");
    }
    if (this.isReplaceMode) {
      return i18n(
        "discourse_revised_critique_image.project_editor.submit_replace_latest"
      );
    }
    return i18n("discourse_revised_critique_image.project_editor.submit_add");
  }

  loadBaseline() {
    const editor = this.topic?.project_revision_editor || {};
    let baseline;
    if (this.isReplaceMode) {
      baseline = editor.latest || editor.original || { images: [], note: "" };
    } else {
      baseline = editor.latest || editor.original || { images: [], note: "" };
    }

    this.images = normalizeBaselineImages(baseline.images);
    this.note = this.isReplaceMode ? baseline.note || "" : "";

    if (this.images.length === 0) {
      // No baseline images — the editor still opens but a save will
      // be blocked client-side by the atMinImages guard. Surface a
      // hint so the OP knows what's missing.
      this.errorMessage = i18n(
        "discourse_revised_critique_image.project_editor.error_no_baseline"
      );
    }
  }

  // positionLabel doesn't reference `this`, so the template's
  // `{{this.positionLabel idx}}` happens to work even unbound; but mark
  // it @action anyway to make the convention consistent with the rest
  // of the file and to survive any future refactor that adds a `this.`
  // reference inside.
  @action
  positionLabel(index) {
    return i18n("discourse_revised_critique_image.project_editor.image_label", {
      number: index + 1,
    });
  }

  @action
  registerFileInput(element) {
    this.uppyUpload.setup(element);
  }

  @action
  updateNote(event) {
    this.note = event.target.value;
  }

  @action
  updateCaption(index, event) {
    const next = [...this.images];
    next[index] = { ...next[index], caption: event.target.value };
    this.images = next;
  }

  @action
  moveUp(index) {
    if (index <= 0) {
      return;
    }
    const next = [...this.images];
    [next[index - 1], next[index]] = [next[index], next[index - 1]];
    this.images = next;
    this.clearError();
  }

  @action
  moveDown(index) {
    if (index >= this.lastIndex) {
      return;
    }
    const next = [...this.images];
    [next[index], next[index + 1]] = [next[index + 1], next[index]];
    this.images = next;
    this.clearError();
  }

  // ---- Drag-and-drop reordering ----------------------------------------
  // Mirrors Discourse's sidebar/section-form-link.gjs pattern: native
  // HTML5 D&D events with a tracked source + over state, and a per-card
  // class hook for the drop indicator. The actual reorder happens on
  // drop; dragOver only updates the "above/below" hint so the user can
  // see where the card will land.

  @action
  onDragStart(cardId, event) {
    event.dataTransfer.effectAllowed = "move";
    // Some browsers refuse to fire drag events without setData being called.
    event.dataTransfer.setData("text/plain", cardId);
    this.dragSourceId = cardId;
  }

  @action
  onDragOver(cardId, event) {
    // preventDefault is required for `drop` to fire on this element.
    event.preventDefault();
    event.dataTransfer.dropEffect = "move";
    if (!this.dragSourceId || cardId === this.dragSourceId) {
      return;
    }
    const rect = event.currentTarget.getBoundingClientRect();
    const above = event.clientY < rect.top + rect.height / 2;
    this.dragOverId = cardId;
    this.dragOverPosition = above ? "above" : "below";
  }

  @action
  onDragLeave(cardId) {
    if (this.dragOverId === cardId) {
      this.dragOverId = null;
      this.dragOverPosition = null;
    }
  }

  @action
  onDrop(targetId, event) {
    event.preventDefault();
    event.stopPropagation();
    const sourceId = this.dragSourceId;
    const position = this.dragOverPosition;
    this.resetDragState();

    if (!sourceId || sourceId === targetId) {
      return;
    }

    const sourceIdx = this.images.findIndex((img) => img.id === sourceId);
    if (sourceIdx === -1) {
      return;
    }

    const next = [...this.images];
    const [moved] = next.splice(sourceIdx, 1);
    const targetIdxAfterRemoval = next.findIndex((img) => img.id === targetId);
    if (targetIdxAfterRemoval === -1) {
      return;
    }
    const insertAt =
      position === "below" ? targetIdxAfterRemoval + 1 : targetIdxAfterRemoval;

    next.splice(insertAt, 0, moved);
    this.images = next;
    this.clearError();
  }

  @action
  onDragEnd() {
    this.resetDragState();
  }

  resetDragState() {
    this.dragSourceId = null;
    this.dragOverId = null;
    this.dragOverPosition = null;
  }

  // Returns the BEM modifier classes that should sit on a card given
  // the current drag state. Inline class={{...}} composition would
  // also work, but the @action method keeps the template readable
  // when there are several states to combine.
  @action
  dragClassFor(cardId) {
    const classes = [];
    if (cardId === this.dragSourceId) {
      classes.push("project-revision-editor__card--dragging");
    }
    if (cardId === this.dragOverId && this.dragOverPosition === "above") {
      classes.push("project-revision-editor__card--drag-above");
    }
    if (cardId === this.dragOverId && this.dragOverPosition === "below") {
      classes.push("project-revision-editor__card--drag-below");
    }
    return classes.join(" ");
  }

  @action
  removeImage(index) {
    if (this.atMinImages) {
      this.errorMessage = i18n(
        "discourse_revised_critique_image.project_editor.error_min_one_image"
      );
      return;
    }
    const next = [...this.images];
    next.splice(index, 1);
    this.images = next;
    this.clearError();
  }

  @action
  triggerAdd() {
    if (this.atMaxImages) {
      this.errorMessage = i18n(
        "discourse_revised_critique_image.project_editor.error_too_many_images",
        { max: this.maxImages }
      );
      return;
    }
    this.nextUploadTarget = { kind: "add" };
    this.uppyUpload.openPicker();
  }

  @action
  triggerReplace(cardId) {
    this.nextUploadTarget = { kind: "replace", id: cardId };
    this.uppyUpload.openPicker();
  }

  // Single sink for every completed upload from the shared UppyUpload.
  routeUpload(upload) {
    const target = this.nextUploadTarget || { kind: "add" };
    this.nextUploadTarget = null;

    if (target.kind === "replace") {
      this.images = this.images.map((img) =>
        img.id === target.id
          ? {
              ...img,
              upload_id: upload.id,
              short_url: upload.short_url,
              image_url: upload.url,
            }
          : img
      );
    } else {
      if (this.atMaxImages) {
        return;
      }
      this.images = [
        ...this.images,
        {
          id: generateLocalId(),
          upload_id: upload.id,
          short_url: upload.short_url,
          image_url: upload.url,
          caption: "",
          alt: `Image ${this.images.length + 1}`,
        },
      ];
    }
    this.clearError();
  }

  clearError() {
    this.errorMessage = null;
  }

  @action
  async save() {
    if (!this.canSave) {
      return;
    }
    this.submitting = true;
    this.errorMessage = null;

    try {
      await ajax(
        `/revised-critique-image/topics/${this.topic.id}/project-revisions`,
        {
          type: "POST",
          data: {
            mode: this.mode,
            note: this.note.trim(),
            images: this.images.map((img) => ({
              id: img.id,
              upload_id: img.upload_id,
              caption: img.caption || "",
            })),
          },
        }
      );

      // Close BEFORE refreshing so the modal is fully unmounted by
      // the time the route re-renders the topic.
      this.args.closeModal();
      this.router.refresh();
    } catch (e) {
      const body = e?.jqXHR?.responseJSON || {};
      const messages = body.errors || [];
      this.errorMessage =
        messages[0] ||
        i18n("discourse_revised_critique_image.project_editor.error_generic");
      popupAjaxError(e);
    } finally {
      this.submitting = false;
    }
  }

  <template>
    <DModal
      class="project-revision-editor -large"
      @title={{this.title}}
      @closeModal={{@closeModal}}
    >
      <:body>
        <p class="project-revision-editor__description">
          {{i18n "discourse_revised_critique_image.project_editor.description"}}
        </p>

        <div class="project-revision-editor__note">
          <label
            for="project-revision-note"
            class="project-revision-editor__note-label"
          >
            {{i18n
              "discourse_revised_critique_image.project_editor.note_label"
            }}
          </label>
          <textarea
            id="project-revision-note"
            class="project-revision-editor__note-input"
            rows="3"
            placeholder={{i18n
              "discourse_revised_critique_image.project_editor.note_placeholder"
            }}
            value={{this.note}}
            {{on "input" this.updateNote}}
          ></textarea>
        </div>

        <div class="project-revision-editor__sequence">
          <h3 class="project-revision-editor__sequence-heading">
            {{i18n
              "discourse_revised_critique_image.project_editor.sequence_heading"
            }}
          </h3>
          <p class="project-revision-editor__sequence-helper">
            {{i18n
              "discourse_revised_critique_image.project_editor.sequence_helper"
            }}
          </p>
        </div>

        <ol class="project-revision-editor__cards" aria-live="polite">
          {{#each this.images key="id" as |card idx|}}
            <li
              class="project-revision-editor__card
                {{this.dragClassFor card.id}}"
              data-card-id={{card.id}}
              data-position={{idx}}
              draggable="true"
              {{on "dragstart" (fn this.onDragStart card.id)}}
              {{on "dragover" (fn this.onDragOver card.id)}}
              {{on "dragleave" (fn this.onDragLeave card.id)}}
              {{on "drop" (fn this.onDrop card.id)}}
              {{on "dragend" this.onDragEnd}}
            >
              <div class="project-revision-editor__card-thumb">
                {{#if card.image_url}}
                  <img
                    class="project-revision-editor__card-image"
                    src={{card.image_url}}
                    alt={{card.alt}}
                    loading="lazy"
                  />
                {{else}}
                  <div class="project-revision-editor__card-placeholder">
                    {{i18n
                      "discourse_revised_critique_image.project_editor.image_pending"
                    }}
                  </div>
                {{/if}}
              </div>
              <div class="project-revision-editor__card-meta">
                <div class="project-revision-editor__card-header">
                  <span class="project-revision-editor__card-position">
                    {{this.positionLabel idx}}
                  </span>
                  <div
                    class="project-revision-editor__card-reorder"
                    role="group"
                    aria-label={{i18n
                      "discourse_revised_critique_image.project_editor.reorder_group_label"
                    }}
                  >
                    <DButton
                      class="btn-flat project-revision-editor__card-move-up"
                      @action={{fn this.moveUp idx}}
                      @disabled={{eq idx 0}}
                      @icon="arrow-up"
                      @title="discourse_revised_critique_image.project_editor.move_up"
                      @ariaLabel="discourse_revised_critique_image.project_editor.move_up"
                    />
                    <DButton
                      class="btn-flat project-revision-editor__card-move-down"
                      @action={{fn this.moveDown idx}}
                      @disabled={{eq idx this.lastIndex}}
                      @icon="arrow-down"
                      @title="discourse_revised_critique_image.project_editor.move_down"
                      @ariaLabel="discourse_revised_critique_image.project_editor.move_down"
                    />
                  </div>
                </div>
                <label class="project-revision-editor__card-caption-label">
                  {{i18n
                    "discourse_revised_critique_image.project_editor.caption_label"
                  }}
                  <input
                    id={{concat "prj-caption-" card.id}}
                    type="text"
                    class="project-revision-editor__card-caption-input"
                    value={{card.caption}}
                    {{on "input" (fn this.updateCaption idx)}}
                  />
                </label>
                <div class="project-revision-editor__card-actions">
                  <DButton
                    class="btn-flat project-revision-editor__card-replace"
                    @action={{fn this.triggerReplace card.id}}
                    @icon="arrows-rotate"
                    @label="discourse_revised_critique_image.project_editor.replace"
                  />
                  <DButton
                    class="btn-flat project-revision-editor__card-remove"
                    @action={{fn this.removeImage idx}}
                    @disabled={{this.atMinImages}}
                    @icon="trash-can"
                    @label="discourse_revised_critique_image.project_editor.remove"
                    @ariaLabel="discourse_revised_critique_image.project_editor.remove"
                  />
                </div>
              </div>
            </li>
          {{/each}}
        </ol>

        <div class="project-revision-editor__add">
          <DButton
            class="btn-default project-revision-editor__add-button"
            @action={{this.triggerAdd}}
            @disabled={{this.atMaxImages}}
            @icon="plus"
            @label="discourse_revised_critique_image.project_editor.add_image"
          />
          <p class="project-revision-editor__add-helper">
            {{i18n
              "discourse_revised_critique_image.project_editor.add_image_helper"
              max=this.maxImages
            }}
          </p>
        </div>

        {{#if this.errorMessage}}
          <p class="project-revision-editor__error" role="alert">
            {{this.errorMessage}}
          </p>
        {{/if}}

        <input
          type="file"
          class="project-revision-editor__file-input"
          accept="image/*"
          aria-hidden="true"
          tabindex="-1"
          {{didInsert this.registerFileInput}}
        />
      </:body>

      <:footer>
        <DButton
          class="btn-primary project-revision-editor__submit"
          @action={{this.save}}
          @disabled={{not this.canSave}}
          @translatedLabel={{this.submitLabel}}
        />
        <DModalCancel @close={{@closeModal}} />
      </:footer>
    </DModal>
  </template>
}
