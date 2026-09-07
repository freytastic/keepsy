abstract final class CreateCopy {
  static const title = 'New album';
  static const namePlaceholder = 'Album name';
  static const nameRequired = 'Give the album a name';

  static const invitePeople = 'Invite people';
  static const addPerson = 'Add person';
  static const idPlaceholder = 'Keepsy ID';
  static const idHint = 'XXXX-XXXX';
  static const idInvalid = 'Enter a valid 8-character Keepsy ID';
  static const idDuplicate = 'That ID is already on the list';
  static const removePerson = 'Remove';
  static const cancel = 'Cancel';

  static const privacyEmpty =
      'Keepsy only ever sees an ID. Names are encrypted inside the album.';
  static const privacyWithInvites = 'Their names appear once they join.';

  static const createOnly = 'Create album';

  static String createAndInvite(int count) =>
      count == 0 ? createOnly : 'Create and invite $count';

  static const keySetupFailed = 'Encryption setup failed for the new album';

  static String invitesFailed(int count) => count == 1
      ? "One invite couldn't be sent. Add them from the album."
      : "$count invites couldn't be sent. Add them from the album.";
}
