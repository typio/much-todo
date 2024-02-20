const addNote = (notesElement: HTMLElement | null, noteId: string, noteBody: string, userVote: string, voteCount: string, isUser: string, edited: string, lastEdit: string) => {
  const newNote = document.createElement('note-c') as Note
  newNote.setAttribute('title', '');
  newNote.setAttribute('noteid', noteId);
  newNote.setAttribute('body', noteBody);
  newNote.setAttribute('uservote', userVote);
  newNote.setAttribute('votes', voteCount);
  newNote.setAttribute('isuser', isUser);
  newNote.setAttribute('edited', edited);
  newNote.setAttribute('lastedit', lastEdit);

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

      data.notes.forEach((note: { id: any; body: any; userVote: any; voteCount: any; isUser: any; edited: any; lastEdit: any }) => {
        addNote(notesElement, note.id, note.body, note.userVote, note.voteCount, note.isUser, note.edited, note.lastEdit)
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

  fetch("/api/httpServer")
    .then(response => response.json())
    .then(data => {
      const requestCountElement = document.getElementById('request-count');
      const onlineTimeElement = document.getElementById('online-time');

      if (requestCountElement && onlineTimeElement) {
        requestCountElement.innerText = data.request_count ?? '';

        setOnlineTimeText(data.server_start_timestamp * 1000, onlineTimeElement);
      }
    })
    .catch(error => {
      console.error("Error fetching view data:", error);
    });
}

const setOnlineTimeText = (timeMs: number, el: HTMLElement) => {
  const differenceMs = new Date().getTime() - timeMs

  const days = Math.floor(differenceMs / (1000 * 60 * 60 * 24))
  const hours = Math.floor(differenceMs / (1000 * 60 * 60)) % 24
  const minutes = Math.floor(differenceMs / (1000 * 60)) % 60
  const seconds = Math.floor(differenceMs / (1000)) % 60

  if (days > 0) {
    el.innerText = ` ${days} day${days > 1 ? 's' : ''}${hours > 0 ? ` and ${hours} hour${hours > 1 ? 's' : ''}` : ''}`
  } else if (hours > 0) {
    el.innerText = ` ${hours} hour${hours > 1 ? 's' : ''}${minutes > 0 ? ` and ${minutes} minute${minutes > 1 ? 's' : ''}` : ''}`
  } else if (minutes > 0) {
    el.innerText = ` ${minutes} minute${minutes > 1 ? 's' : ''}${seconds > 0 ? ` and ${seconds} second${seconds > 1 ? 's' : ''}` : ''}`
  } else {
    el.innerText = ` ${seconds} second${seconds > 1 ? 's' : ''}`
  }
  setTimeout(() => {
    setOnlineTimeText(timeMs, el)
  }, days + hours === 0 ? 333 : days === 0 ? 20 * 1000 : 20 * 60 * 1000)
}