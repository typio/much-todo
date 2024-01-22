const addNote = (notesElement: HTMLElement | null, noteId: string, noteBody: string, userVote: string, voteCount: string, isUser: string) => {
  const newNote = document.createElement('note-item') as NoteItem
  newNote.setAttribute('title', '');
  newNote.setAttribute('noteid', noteId);
  newNote.setAttribute('body', noteBody);
  newNote.setAttribute('uservote', userVote);
  newNote.setAttribute('votes', voteCount);
  newNote.setAttribute('isuser', isUser);
  if (notesElement)
    notesElement.append(newNote);
  newNote.render()
}

const getNotes = () => {
  fetch('/api/notes')
    .then(response => response.json())
    .then(data => {
      const notesElement = document.getElementById('notes');
      if (notesElement)
        notesElement.innerHTML = ''

      data.notes.forEach((note: { id: any; body: any; userVote: any; voteCount: any; isUser: any; }) => {
        addNote(notesElement, note.id, note.body, note.userVote, note.voteCount, note.isUser)
      })
    })
    .catch(error => {
      console.error('Error fetching notes:', error);
    });
}

window.onload = () => {
  const headerElement = document.getElementById('header')
  const titleElement = document.getElementById('title')
  const subtitleElement = document.getElementById('subtitle')
  const noteInputElement = document.getElementById('note-input') as HTMLInputElement

  if (subtitleElement)
    subtitleElement.innerHTML = subtitleElement.innerHTML.replace(/(\d{2})+/g, (new Date().getDate() % 6 + 24) + '')
  let prevScrollY = 0
  window.addEventListener('scroll', () => {
    if (headerElement && titleElement && subtitleElement)
      if (prevScrollY <= 0 && window.scrollY > 0) {
        headerElement.classList.add('header-scrolled', 'transition')
        titleElement.classList.add('title-scrolled', 'transition')
        subtitleElement.classList.add('subtitle-scrolled', 'transition')
      } else if (prevScrollY > 0 && window.scrollY <= 0) {
        headerElement.classList.remove('header-scrolled')
        titleElement.classList.remove('title-scrolled')
        subtitleElement.classList.remove('subtitle-scrolled')
      }
    prevScrollY = window.scrollY
  })

  const postNote = () => {
    const noteBody = noteInputElement?.value ?? '';
    if (noteBody.trim() === '') return;
    noteInputElement.value = ''

    fetch("/api/notes", {
      method: "POST",
      body: JSON.stringify({ title: '', body: noteBody }),
      headers: { "Content-type": "application/json;" }
    }).then((e) => {
      // Simple get is ok, so I don't have to reimplement app logic here
      getNotes()
    });
  };

  document?.getElementById('note-post')?.addEventListener('click', postNote);

  getNotes()

  fetch("/api/viewCount")
    .then(response => response.json())
    .then(data => {
      const pageViewCountElement = document.getElementById('page-views');
      const uniqueVisitorCountElement = document.getElementById('unique-visitors');
      if (pageViewCountElement && uniqueVisitorCountElement) {
        pageViewCountElement.innerText = data.view_count ?? '';
        uniqueVisitorCountElement.innerText = data.unique_ip_count ?? '';
      }
    })
    .catch(error => {
      console.error("Error fetching view data:", error);
    });
}

class NoteItem extends HTMLElement {
  static get observedAttributes() {
    return ['body', 'noteid', 'uservote', 'isuser', 'votes'];
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
    const body = this.getAttribute('body')?.replace(/\n/g, '<br>');
    const userVote = Number(this.getAttribute('userVote'));
    const voteCount = this.getAttribute('votes') ?? 0;
    const isUser = this.getAttribute('isuser') === 'true';

    const html = String.raw;
    this.shadowRoot.innerHTML = html`
      <div class="note">
        ${isUser ?
        html`<button id="delete-${noteId}" class="note-delete-btn">✖</button>` :
        html``
      }
        <p class="note-body">${body}</p>
        <div class="bottom-row">
        ${voteCount != 0 ?
        html`<p class="vote-tally">${voteCount}</p>` :
        html``
      }
          <button class="vote-btn" id="vote-up-btn">${userVote === 1 ? '⬆' : '⇧'}</button>
          <button class="vote-btn" id="vote-down-btn">${userVote === -1 ? '⬇' : '⇩'}</button>
        </div>
      </div>
      <style>
        .note {
          background-color: rgb(242, 239, 222);
          margin: 4px;
          padding: 12px;
          padding-right: 52px;
          padding-bottom: 44px;
          border-radius: 8px;
          position: relative;
          min-width: 100px;
          overflow-wrap: break-word;
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
          color: black;
          opacity: 0.3;
        }

        .note-delete-btn:hover {
          opacity: 0.5;
          border-radius: 8px;
        }

        .note-body {
          margin: 0;
          text-align: left;
        }

        .bottom-row {
          position: absolute;
          bottom: 4px;
          right: 8px;
          display: flex;
          flex-direction: row;
          margin-top: 4px;
          justify-content: end;
          align-items:center;
          margin-right: 10px;
        }

        .vote-tally {
          font-size: 0.95rem;
          color: rgb(142, 139, 122);
          margin: 0;
          margin-right: 4px;
        }

        .vote-btn {
          background: none;
          border: none;
          padding:0;
          height: 36px;
          width: 24px;
          font-size: 1.1rem;
          opacity: 0.3;
        }

        .vote-btn:hover {
          opacity: 0.5;
        }
    </style>
    `;


    if (isUser)
      this.shadowRoot.querySelector(`#delete-${noteId}`)?.addEventListener('click', () => {
        if (confirm("Are you sure you want to permanently delete this note?") == true) {
          fetch("/api/notes", {
            method: "DELETE",
            body: JSON.stringify({ noteId: noteId }),
            headers: { "Content-type": "application/json;" }
          }).then(() => getNotes());
        }
      });

    this.shadowRoot.querySelector(`#vote-up-btn`)?.addEventListener('click', () => {
      fetch("/api/notes/vote", {
        method: "POST",
        body: JSON.stringify({ noteId: noteId, like: true }),
        headers: { "Content-type": "application/json;" }
      }).then(() => getNotes());
    });

    this.shadowRoot.querySelector(`#vote-down-btn`)?.addEventListener('click', () => {
      fetch("/api/notes/vote", {
        method: "POST",
        body: JSON.stringify({ noteId: noteId, like: false }),
        headers: { "Content-type": "application/json;" }
      }).then(() => getNotes());
    });
  }
}

customElements.define("note-item", NoteItem)

