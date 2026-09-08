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
