import Component from "@glimmer/component";
import { action } from "@ember/object";
import { service } from "@ember/service";
import DButton from "discourse/ui-kit/d-button";
import { i18n } from "discourse-i18n";
import RevisedImageModal from "./modal/revised-image-modal";

export default class RevisedImageBanner extends Component {
  @service modal;
  @service siteSettings;

  get topic() {
    return this.args.outletArgs?.model;
  }

  get pluginEnabled() {
    return Boolean(this.siteSettings.revised_critique_enabled);
  }

  get canAdd() {
    return Boolean(this.topic?.can_add_revised_critique_image);
  }

  get canReplaceLatest() {
    return Boolean(this.topic?.can_replace_latest_revised_critique_image);
  }

  get show() {
    return this.pluginEnabled && (this.canAdd || this.canReplaceLatest);
  }

  get hasRevisions() {
    return (this.topic?.revised_critique_image_revision_count || 0) > 0;
  }

  // Three states: before first revision, between, at max.
  // - canAdd && !hasRevisions → state "first"
  // - canAdd && hasRevisions → state "mixed" (both buttons)
  // - !canAdd && canReplaceLatest → state "atMax"
  get state() {
    if (!this.hasRevisions) {
      return "first";
    }
    return this.canAdd ? "mixed" : "atMax";
  }

  get message() {
    switch (this.state) {
      case "first":
        return i18n("discourse_revised_critique_image.eligible_message");
      case "mixed":
        return i18n(
          "discourse_revised_critique_image.can_replace_or_add_message"
        );
      case "atMax":
        return i18n("discourse_revised_critique_image.at_max_message");
    }
    return "";
  }

  get primaryButtonLabel() {
    if (this.state === "first") {
      return (
        this.siteSettings.revised_critique_button_label ||
        i18n("discourse_revised_critique_image.button_label")
      );
    }
    return i18n("discourse_revised_critique_image.replace_latest_label");
  }

  get primaryButtonMode() {
    return this.state === "first" ? "add" : "replace_latest";
  }

  get primaryButtonIcon() {
    return this.state === "first" ? "image" : "arrows-rotate";
  }

  get showAddAnotherButton() {
    return this.state === "mixed";
  }

  get stateClass() {
    // "first" | "mixed" | "atMax" → CSS-safe BEM modifier suffix
    const suffix = this.state === "atMax" ? "at-max" : this.state;
    return `revised-image-banner--${suffix}`;
  }

  @action
  openPrimary() {
    this.openModal(this.primaryButtonMode);
  }

  @action
  openAddAnother() {
    this.openModal("add");
  }

  openModal(mode) {
    this.modal.show(RevisedImageModal, {
      model: { topic: this.topic, mode },
    });
  }

  <template>
    {{#if this.show}}
      <div
        class="revised-image-banner {{this.stateClass}}"
        data-revised-image-banner-state={{this.state}}
      >
        <p class="revised-image-banner__message">{{this.message}}</p>
        <div class="revised-image-banner__actions">
          <DButton
            class="btn-primary revised-image-banner__button revised-image-banner__primary"
            @action={{this.openPrimary}}
            @icon={{this.primaryButtonIcon}}
            @translatedLabel={{this.primaryButtonLabel}}
          />
          {{#if this.showAddAnotherButton}}
            <DButton
              class="btn-default revised-image-banner__button revised-image-banner__secondary"
              @action={{this.openAddAnother}}
              @icon="plus"
              @label="discourse_revised_critique_image.add_another_label"
            />
          {{/if}}
        </div>
      </div>
    {{/if}}
  </template>
}
