const maxNoteBodyWidth = Math.min(420, window.innerWidth - 96)
const minNoteBodyWidth = 160

const loadingIcon = () => html`<svg width='20px' height='20px'>
<circle cx="10" cy="10" r="8" fill="none" stroke="var(--primarydark)" stroke-width="3" />
<circle cx="10" cy="10" r="8" fill="none" stroke="var(--textdark)" stroke-width="3" stroke-dasharray="${8 * 2 * Math.PI * .666}" style="
  animation: rotating 1s linear infinite;
  transform-origin: center;" 
/>
</svg>`

const lastEditText = (edited, lastEdit = new Date()) => {
  const sameDay = lastEdit?.getDate() === new Date().getDate() &&
    lastEdit?.getMonth() === new Date().getMonth() &&
    lastEdit?.getFullYear() === new Date().getFullYear();

  const sameYear = lastEdit?.getFullYear() === new Date().getFullYear();

  const timestampString = sameDay ? lastEdit.toLocaleTimeString(undefined, { minute: 'numeric', hour: 'numeric' }) : sameYear ? lastEdit.toLocaleString(undefined, { month: 'short', day: 'numeric' }) : lastEdit.toLocaleString(undefined, { year: 'numeric', month: 'short', day: 'numeric' })

  return html`<p class="last-edit-text">${edited ? 'Edited' : 'Created'} ${timestampString}</p>`
}
class Note extends HTMLElement {
  localVote = 0
  isEditing = false

  static get observedAttributes() {
    return ['body', 'noteid', 'uservote', 'isuser', 'votes', 'edited', 'lastedit'];
  }

  constructor() {
    super();
    this.attachShadow({ mode: 'open' });
  }

  // attributeChangedCallback(name, oldValue, newValue) {
  //   if (name === 'body' || name === 'noteid' || name === 'uservote' || name === 'votes' || name === 'isuser') {
  //     this.render();
  //   }
  // }

  render() {
    if (this.shadowRoot === null) return

    const noteId = this.getAttribute('noteid');
    const body = this.getAttribute('body')//?.replace(/\n/g, '<br>');
    let userVote = Number(this.getAttribute('userVote'));
    const voteCount = (Number(this.getAttribute('votes')) ?? 0);
    const isUser = this.getAttribute('isuser') === 'true';

    const edited = this.getAttribute('edited') === 'true'

    const lastEdit = ((d) => d ? new Date(Number(d)) : new Date())(this.getAttribute('lastedit'))

    let displayVote = voteCount

    if (this.localVote === 1) {
      if (userVote === 1) { userVote = 0; displayVote-- }
      else if (userVote === -1) { userVote = 1; displayVote += 2 }
      else { userVote = this.localVote; displayVote++ }
    } else if (this.localVote === -1) {
      if (userVote === 1) { userVote = -1; displayVote -= 2 }
      else if (userVote === -1) { userVote = 0; displayVote++ }
      else { userVote = this.localVote; displayVote-- }
    }
    // FIXME: Partially incorrect behavior after multiple local votes, because userVote changes are't persisted 

    this.shadowRoot.innerHTML = html`
      <div class="note">
        ${isUser ?
        html`<button aria-label="delete note" id="delete-${noteId}" class="note-delete-btn">✖</button>` :
        html``
      }
        <textarea class="note-body" id="note-body" ${isUser ? '' : 'readonly'}>${body}</textarea>
        <div class="bottom-row">
          <span id="bottom-row-left">${lastEditText(edited, lastEdit)}</span>
          <div class="bottom-row-right">
        ${displayVote != 0 ?
        html`<p class="vote-tally">${displayVote}</p>` :
        html``
      }
          <button aria-label="like note" class="vote-btn" id="vote-up-btn">
          <div class="like-icon-container">${userVote === 1 ? activeLikeIconSVG : likeIconSVG}</div>
          </button>
          <button aria-label="dislike note" class="vote-btn" id="vote-down-btn">
          <div class="like-icon-container">${userVote === -1 ? activeDislikeIconSVG : dislikeIconSVG}</div>
        </button>
        </div>
        </div>
      </div>
      <style>
        @keyframes rotating {
          from {
            transform: rotate(0);
          }
          to {
            transform: rotate(6.283rad);
          }
        }

        .note {
          background-color: var(--primary);
          margin: 5px;
          padding: 12px;
          padding-bottom: 0;
          border-radius: 8px;
          position: relative;
          overflow-wrap: anywhere;
        }

        .note-delete-btn {
          position: absolute;
          width: 44px;
          height: 44px;
          right: 0px;
          top: 0px;
          padding:0;
          background: none;
          border: none;
          color: var(--text);
          opacity: 0.7;
        }

        .note-delete-btn:hover {
          opacity: 1;
        }

        .note-body {
          margin: 0;
          text-align: left;
          color: var(--text);
          outline: none;
          border: none;
          background: none;
          font-size: 1rem;
          font-family: "Inter";
          min-width: 100px;
          resize: none;
          margin-right: 32px;
        }

        .bottom-row {
          height: 30px;
          display: flex;
          flex-direction: row;
          margin-top: 4px;
          justify-content: space-between;
          align-items:center;
          margin-right: 0px;
        }

        .bottom-row-right {
          display: flex;
          flex-direction: row;
          align-items:center;
        }

        .last-edit-text {
          font-size: 11px;
        }

        .vote-tally {
          font-size: 0.85rem;
          color: var(--text);
          margin: 0;
          margin-right: 8px;
          font-weight: 600;
        }

        .vote-btn {
          background: none;
          border: none;
          padding:0;
          height: 30px;
          width: 30px;
          display:flex;
          justify-content: center;
          align-items: center;
          font-size: 1.1rem;
          opacity: 0.7;
        }

        .like-icon-container {
          width: 16px;
          height: 16px;
        }

        .vote-btn:hover {
          opacity: 1;
        }
    </style>
    `;

    this.addEventListeners(noteId);
    this.adjustTextareaSize(noteId);
  }

  adjustTextareaSize(noteId) {
    const textarea = this.shadowRoot?.getElementById('note-body') as HTMLTextAreaElement;
    const bottomLeft = this.shadowRoot?.getElementById('bottom-row-left') as HTMLSpanElement

    let measuringSpan = this.shadowRoot?.getElementById('measuring-span');
    if (!measuringSpan) {
      measuringSpan = document.createElement('span');
      measuringSpan.id = 'measuring-span';
      this.shadowRoot?.appendChild(measuringSpan);
      measuringSpan.style.visibility = 'hidden';
      measuringSpan.style.position = 'fixed';
      measuringSpan.style.whiteSpace = 'pre';
      measuringSpan.style.overflow = 'hidden';
      measuringSpan.style.fontFamily = getComputedStyle(textarea).fontFamily;
      measuringSpan.style.fontSize = getComputedStyle(textarea).fontSize;
      measuringSpan.style.fontWeight = getComputedStyle(textarea).fontWeight;
    }

    const updateSize = () => {
      const lines = textarea.value.split('\n');
      let maxWidthRequired = minNoteBodyWidth;

      lines.forEach(line => {
        if (!measuringSpan) return
        measuringSpan.textContent = line;
        maxWidthRequired = Math.max(maxWidthRequired, measuringSpan.offsetWidth + 5);
      });

      textarea.style.width = `${Math.min(maxWidthRequired, maxNoteBodyWidth)}px`;
      textarea.style.height = 'auto';
      textarea.style.height = `${textarea.scrollHeight}px`;
    };

    updateSize();

    textarea.addEventListener('input', () => {
      updateSize()
      if (!this.isEditing) {
        bottomLeft.innerHTML = loadingIcon()
        this.isEditing = true
      }
    });

    textarea.addEventListener('input', debounce((e) => {
      fetch("/api/notes/edit/body", {
        method: "PATCH",
        body: JSON.stringify({ noteId, body: textarea.value }),
        headers: { "Content-type": "application/json;" }
      }).then((res) => {
        // TODO: Get a response here to set lastEditText params with correct values
        // console.log(res)

        bottomLeft.innerHTML = lastEditText(true, new Date())
        this.isEditing = false
      });
    }, 1000));
  }

  addEventListeners(noteId) {
    this.shadowRoot?.querySelector('#vote-up-btn')?.addEventListener('click', () => this.handleVote(noteId, 1));
    this.shadowRoot?.querySelector('#vote-down-btn')?.addEventListener('click', () => this.handleVote(noteId, -1));
    this.shadowRoot?.querySelector(`#delete-${noteId}`)?.addEventListener('click', () => this.handleDelete(noteId));
  }

  handleVote(noteId, newVote) {
    if (this.localVote === newVote)
      this.localVote = 0;
    else
      this.localVote = newVote;

    // FIXME: We can't just rerender without a new GET, loses local state e.g. body edit
    this.render();

    fetch("/api/notes/vote", {
      method: "PUT",
      body: JSON.stringify({ noteId, like: newVote === 1 }),
      headers: { "Content-type": "application/json;" }
    }).then(() => {
      this.render();
    });
  }

  handleDelete(noteId) {
    if (confirm("Are you sure you want to permanently delete this note?")) {
      fetch("/api/notes", {
        method: "DELETE",
        body: JSON.stringify({ noteId }),
        headers: { "Content-type": "application/json;" }
      }).then(() => {
        this.remove();
      });
    }
  }
}

customElements.define("note-c", Note)