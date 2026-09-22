abstract final class AlbumCopy {
  static const back = 'Back to albums';
  static const more = 'More';

  static const select = 'Select';
  static const download = 'Download';
  static const addPhotos = 'Add photos';

  static const selectPhotos = 'Select photos';
  static const downloadAlbum = 'Download album';
  static const peopleAndSafety = 'People & safety numbers';
  static const albumInfo = 'Album info';
  static const openAlbum = 'Open album';
  static const addSomeone = 'Add someone';

  static const addTitle = 'Add someone';
  static String addTo(String album) => 'to $album';
  static const addHelp =
      "Ask for their keepsy ID. It's on their profile, under their name.";
  static const addPaste = 'Paste';
  static const addGo = 'Add to album';
  static const addFinding = 'Finding them…';
  static const addYours = 'They need yours? ';
  static const addCopy = 'Copy';
  static const addCopied = 'Copied';
  static const addUnknown =
      'Nobody has this ID. Check it with them, one letter at a time.';
  static const addSelf = "That's your own ID. Theirs is on their profile.";
  static const addAlready = "They're already in this album.";
  static const addFull = 'This album is full. It can hold 10 people.';
  static const addRotating =
      "This album's key is being updated. Try again in a minute.";
  static const addFailed = "Couldn't add them right now. Try again.";
  static const addDoneTitle = 'Invited';
  static String addDoneBody(String album) =>
      ' can open $album the next time they open Keepsy, with every photo '
      'already in it.';
  static const addDoneNote =
      "The album's key went to their phone, locked so only that phone can "
      'open it. Their name shows up here once they do.';
  static const addAnother = 'Add another';
  static const addDone = 'Done';
  static const invitedPending = "Invited, hasn't opened it yet";

  // Keeps unfinished actions visible without pretending they work
  static const laterBadge = 'Soon';

  static String onlyTheirPhotos(String? name) =>
      name == null ? 'Only their photos' : "Only $name's photos";

  static String filteredBy(String? name, int count) {
    final whose = name == null ? 'Their' : "$name's";
    return '$whose photos · $count';
  }

  static const clearFilter = 'Show everyone';

  static String nothingFrom(String? name) => name == null
      ? 'Nothing from them in here yet.'
      : 'Nothing from $name in here yet.';

  static const infoTitle = 'Album info';
  static const infoCreated = 'Created';
  static const infoPhotos = 'Photos';
  static const infoSize = 'Size';
  static const infoPeople = 'People';
  static const infoLast = 'Last photo';
  static const infoNone = 'None yet';
  static const infoKey =
      'Only its members hold the key, so the server stores it without being '
      'able to open it';
  static const infoStorage = 'Who added what';
  static const infoStorageEmpty = 'Nothing has been added yet.';
  static const infoExactBytes = 'Exact, because sizes are stored alongside '
      'each photo. Nothing is unwrapped on a server to count it.';

  static const save = 'Save';
  static const delete = 'Delete';
  static const sayPlaceholder = 'Say something';
  static const sayAdd = 'Add';
  static const deleteTitle = 'Delete this photo?';
  static const deleteBody =
      'It goes for everyone in the album, and it cannot be undone.';
  static const deleteConfirm = 'Delete';
  static const deleteCancel = 'Keep';
  static const deleteFailed = 'Could not delete that photo.';
  static const unknownMember = 'Someone';
}
