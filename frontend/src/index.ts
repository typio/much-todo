const html = String.raw;

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

const likeIconSVG = html`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="var(--text)"><path d="M14.5998 8.00033H21C22.1046 8.00033 23 8.89576 23 10.0003V12.1047C23 12.3659 22.9488 12.6246 22.8494 12.8662L19.755 20.3811C19.6007 20.7558 19.2355 21.0003 18.8303 21.0003H2C1.44772 21.0003 1 20.5526 1 20.0003V10.0003C1 9.44804 1.44772 9.00033 2 9.00033H5.48184C5.80677 9.00033 6.11143 8.84246 6.29881 8.57701L11.7522 0.851355C11.8947 0.649486 12.1633 0.581978 12.3843 0.692483L14.1984 1.59951C15.25 2.12534 15.7931 3.31292 15.5031 4.45235L14.5998 8.00033ZM7 10.5878V19.0003H18.1606L21 12.1047V10.0003H14.5998C13.2951 10.0003 12.3398 8.77128 12.6616 7.50691L13.5649 3.95894C13.6229 3.73105 13.5143 3.49353 13.3039 3.38837L12.6428 3.0578L7.93275 9.73038C7.68285 10.0844 7.36341 10.3746 7 10.5878ZM5 11.0003H3V19.0003H5V11.0003Z"></path></svg>`
const activeLikeIconSVG = html`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="var(--text)"><path d="M2 8.99997H5V21H2C1.44772 21 1 20.5523 1 20V9.99997C1 9.44769 1.44772 8.99997 2 8.99997ZM7.29289 7.70708L13.6934 1.30661C13.8693 1.13066 14.1479 1.11087 14.3469 1.26016L15.1995 1.8996C15.6842 2.26312 15.9026 2.88253 15.7531 3.46966L14.5998 7.99997H21C22.1046 7.99997 23 8.8954 23 9.99997V12.1043C23 12.3656 22.9488 12.6243 22.8494 12.8658L19.755 20.3807C19.6007 20.7554 19.2355 21 18.8303 21H8C7.44772 21 7 20.5523 7 20V8.41419C7 8.14897 7.10536 7.89462 7.29289 7.70708Z"></path></svg>`
const dislikeIconSVG = html`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="var(--text)"><path d="M9.40017 16H3C1.89543 16 1 15.1046 1 14V11.8957C1 11.6344 1.05118 11.3757 1.15064 11.1342L4.24501 3.61925C4.3993 3.24455 4.76447 3 5.16969 3H22C22.5523 3 23 3.44772 23 4V14C23 14.5523 22.5523 15 22 15H18.5182C18.1932 15 17.8886 15.1579 17.7012 15.4233L12.2478 23.149C12.1053 23.3508 11.8367 23.4184 11.6157 23.3078L9.80163 22.4008C8.74998 21.875 8.20687 20.6874 8.49694 19.548L9.40017 16ZM17 13.4125V5H5.83939L3 11.8957V14H9.40017C10.7049 14 11.6602 15.229 11.3384 16.4934L10.4351 20.0414C10.3771 20.2693 10.4857 20.5068 10.6961 20.612L11.3572 20.9425L16.0673 14.27C16.3172 13.9159 16.6366 13.6257 17 13.4125ZM19 13H21V5H19V13Z"></path></svg>`
const activeDislikeIconSVG = html`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="var(--text)"><path d="M22 15H19V3H22C22.5523 3 23 3.44772 23 4V14C23 14.5523 22.5523 15 22 15ZM16.7071 16.2929L10.3066 22.6934C10.1307 22.8693 9.85214 22.8891 9.65308 22.7398L8.8005 22.1004C8.3158 21.7369 8.09739 21.1174 8.24686 20.5303L9.40017 16H3C1.89543 16 1 15.1046 1 14V11.8957C1 11.6344 1.05118 11.3757 1.15064 11.1342L4.24501 3.61925C4.3993 3.24455 4.76447 3 5.16969 3H16C16.5523 3 17 3.44772 17 4V15.5858C17 15.851 16.8946 16.1054 16.7071 16.2929Z"></path></svg>`


window.onload = () => {
  const headerElement = document.getElementById('header')
  const titleElement = document.getElementById('title')
  const subtitleElement = document.getElementById('subtitle')
  const noteInputElement = document.getElementById('note-input') as HTMLInputElement

  if (subtitleElement)
    subtitleElement.innerHTML = html`A notes app for the ${(new Date().getDate() % 6 + 24)}<sup>th</sup> century`
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

    this.shadowRoot.innerHTML = html`
      <div class="note">
        ${isUser ?
        html`<button aria-label="delete note" id="delete-${noteId}" class="note-delete-btn">✖</button>` :
        html``
      }
        <p class="note-body">${body}</p>
        <div class="bottom-row">
        ${voteCount != 0 ?
        html`<p class="vote-tally">${voteCount}</p>` :
        html``
      }
          <button aria-label="like note" class="vote-btn" id="vote-up-btn">
            <div class="like-icon-container">
              ${userVote === 1 ? activeLikeIconSVG : likeIconSVG}
            </div>
          </button>
          <button aria-label="dislike note" class="vote-btn" id="vote-down-btn">
            <div class="like-icon-container">
              ${userVote === -1 ? activeDislikeIconSVG : dislikeIconSVG}
            </div>
        </button>
        </div>
      </div>
      <style>
        .note {
          background-color: var(--primary);
          color: var(--text);
          margin: 5px;
          padding: 12px;
          padding-right: 52px;
          padding-bottom: 44px;
          border-radius: 8px;
          position: relative;
          min-width: 100px;
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
        }

        .bottom-row {
          position: absolute;
          bottom: 4px;
          right: 4px;
          display: flex;
          flex-direction: row;
          margin-top: 4px;
          justify-content: end;
          align-items:center;
          margin-right: 0px;
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

