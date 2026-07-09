import { Controller } from "@hotwired/stimulus"

const STORAGE_KEY = "papl-sidebar-collapsed"

export default class extends Controller {
  static targets = ["sidebar", "toggleButton", "expandIcon", "collapseIcon"]

  connect() {
    this.handleResize = this.handleResize.bind(this)
    const storedState = window.localStorage.getItem(STORAGE_KEY)
    const desktop = window.matchMedia("(min-width: 1024px)").matches
    const collapsed = desktop ? false : (storedState === null ? true : storedState === "true")

    this.applyState(collapsed)
    window.addEventListener("resize", this.handleResize)
  }

  disconnect() {
    window.removeEventListener("resize", this.handleResize)
  }

  toggle(event) {
    event.preventDefault()
    this.applyState(!this.collapsed)
  }

  handleResize() {
    const desktop = window.matchMedia("(min-width: 1024px)").matches
    this.applyState(desktop ? false : this.collapsed)
  }

  applyState(collapsed) {
    this.collapsed = collapsed
    const desktop = window.matchMedia("(min-width: 1024px)").matches

    this.element.classList.toggle("sidebar-collapsed", collapsed)
    this.element.classList.toggle("sidebar-expanded", !collapsed)
    window.localStorage.setItem(STORAGE_KEY, String(collapsed))

    if (this.hasSidebarTarget) {
      this.sidebarTarget.setAttribute("aria-hidden", (!desktop && collapsed).toString())
    }

    if (this.hasToggleButtonTarget) {
      const label = collapsed ? (desktop ? "Expand sidebar" : "Show menu") : "Hide menu"
      this.toggleButtonTarget.setAttribute("aria-label", label)
      this.toggleButtonTarget.setAttribute("title", label)
      this.toggleButtonTarget.setAttribute("aria-expanded", (!collapsed).toString())
    }

    if (this.hasExpandIconTarget) {
      this.expandIconTarget.hidden = !collapsed
    }

    if (this.hasCollapseIconTarget) {
      this.collapseIconTarget.hidden = collapsed
    }
  }
}
