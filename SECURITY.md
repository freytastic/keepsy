# Security

If you find a serious security or protocol bug, reach out to me first:

- **Signal:** `freya.47`
- **Discord:** `freytastic`
- **Email:** [uExistentialist@proton.me](mailto:uExistentialist@proton.me)
- [GitHub private vulnerability reporting](https://github.com/freytastic/keepsy/security/advisories/new)

I reply fastest on Signal and Discord.

A useful report says what you found, why it matters, how to reproduce it and which commit you tested against.

## What counts

Anything that breaks a promise the [protocol pages](https://www.miuchio.com/protocol/overview) make, for example:

- reading photos, names, album titles or keys without being a member of the album,
- a server or database copy learning more than the protocol pages say it can,
- a removed member opening photos added after their removal,
- getting a phone to accept a key or signature it should refuse,
- metadata such as location surviving in an uploaded photo.

Known limits are listed on [What Keepsy does not protect](https://www.miuchio.com/protocol/limits). A way to make one of them worse than the page says still counts.

## Status

The protocol and the code have not had an independent security review yet.
