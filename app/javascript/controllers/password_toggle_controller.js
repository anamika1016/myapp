import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["input", "showIcon", "hideIcon", "button"]

  connect() {
    this.updateState()
  }

  toggle(event) {
    event.preventDefault()
    this.inputTarget.type = this.inputTarget.type === "password" ? "text" : "password"
    this.updateState()
  }

  updateState() {
    const showingPassword = this.inputTarget.type === "text"

    this.showIconTarget.hidden = showingPassword
    this.hideIconTarget.hidden = !showingPassword
    this.buttonTarget.setAttribute("aria-label", showingPassword ? "Hide password" : "Show password")
    this.buttonTarget.setAttribute("aria-pressed", showingPassword.toString())
  }
}
