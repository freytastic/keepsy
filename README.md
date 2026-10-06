# Miuchio

A shared photo album for small groups, end-to-end encrypted. Photos are locked on your phone before they are uploaded, and only the people in the album hold the keys. The server stores the locked copies and enforces the album's rules, but it is never given the keys to open them.

[Website](https://www.miuchio.com) · [How it works](https://www.miuchio.com/how-it-works) · [Protocol](https://www.miuchio.com/protocol/overview) · [What Miuchio does not protect](https://www.miuchio.com/protocol/limits)

## What Miuchio is

Miuchio is meant for a family, a group of friends or the people from one trip: a quiet place to keep photos together, not a feed. Everyone in an album can add photos, and nobody outside it can open them, including the server.

- **Photos, album titles, names and profile photos are encrypted** on the phone. The server only ever holds ciphertext.
- **Location and camera details are removed** before a photo is encrypted. If that cannot be done, the photo is not uploaded.
- **Your email address is not stored.** The database keeps only a keyed hash of it. People add you with a random Miuchio ID, never by email, phone number or contacts.
- **Removing someone locks them out of what comes next.** The album moves to a new key that only the remaining members receive.
- **You can check you have the right keys** by comparing a safety number with the other person.

The [How it works](https://www.miuchio.com/how-it-works) page walks through one album from start to finish in plain language.

## Status

Miuchio is in its **testing phase**. Beta v1 is not on the App Store or Play Store yet, so expect some bugs in the UI and the odd glitch while you try it.

- An album holds up to 10 people and has one admin, the person who created it.
- There is no backup and no second device yet. Removing the app or losing your phone means losing access to your albums.
- **The protocol and the code have not had an independent security review.** Do not rely on it yet where a failure would put someone at risk.

Every known limit is listed on [What Miuchio does not protect](https://www.miuchio.com/protocol/limits).

## Roadmap

| Release | What it adds |
| --- | --- |
| **Beta v1** (in testing) | Encrypted albums, invites by Miuchio ID, removal with a new album key, safety numbers, encrypted names, titles and profile photos, an upload queue that survives the app closing, offline browsing of cached albums and photos, account deletion |
| **Beta v2** (planned) | Videos, comments and heart reactions |
| **Beta v3** (planned) | Backup: save a backup before you remove the app and get your albums back afterwards |

## How it works in brief

Most of the cryptography is standard: Ed25519, X25519, HKDF-SHA256 and AES-256-GCM, with libsodium on the phone. Keys are organised in three layers, so that changing who is in an album never means encrypting a photo again:

```
Identity keys     each phone's own keys; private halves never leave it
     │            a handshake based on Signal's X3DH delivers...
     ▼
Album key         one random key per epoch; a new epoch starts when someone leaves
     │            which encrypts...
     ▼
Photo keys        a random key for each photo and another for its thumbnail
```

The parts I designed myself, such as epochs, signed key changes, the upload freeze during a removal and how the database reduces identifying membership metadata, are explained with their reasons in the [Protocol overview](https://www.miuchio.com/protocol/overview).

## Repository layout

| Path | What is in it |
| --- | --- |
| `server/` | Go API server. Postgres for data, Redis for sign-in codes and rate limits, S3 compatible storage for encrypted files |
| `server/internal/e2ee/` | The server's protocol checks: prekeys, epochs and invites |
| `server/migrations/` | Database schema, applied automatically when the server starts |
| `server/cmd/` | The server, plus generators for the known answer test vectors |
| `frontend/` | Flutter app for Android and iPhone |
| `frontend/lib/crypto/` | Primitives, the X3DH handshake and the wire formats |
| `frontend/lib/e2ee/` | Epochs, invites, removal, trust and the photo pipeline |
| `frontend/lib/secure_store/` | Key storage backed by the Android Keystore and the Secure Enclave |
| `frontend/android/`, `frontend/ios/` | Native code for the key store and, on Android, photo processing |
| `test_vectors/` | Known answer tests that the Go server and the Dart app must both match byte for byte |
| `tools/` | Development scripts for performance traces and onboarding animations |

## Running locally

### What you need

- Docker with Docker Compose
- [Flutter](https://docs.flutter.dev/get-started/install) 3.44 or newer on the stable channel, with Dart 3.12 or newer
- For Android: Android Studio or the Android SDK, and a phone or emulator
- For iPhone: a Mac with Xcode, and a phone or simulator
- Go 1.26.1 or newer, only if you want to run the server or its tests outside Docker

The app builds libsodium from source on the first build, using the normal build tools of your platform.

### 1. Start the server

```bash
cp .env.example .env
```

In `.env`, set `S3_PUBLIC_ENDPOINT` to your computer's LAN IP, for example `http://192.168.1.10:9000`. The phone downloads photos from that address, so it has to be reachable from the phone.

```bash
docker compose up --build
```

This starts Postgres, Redis, MinIO and the server on port 8080, with live reload when you edit server code. The server applies migrations and creates the storage bucket on start. Check it with:

```bash
curl http://localhost:8080/health
```

`APP_ENV=dev` lets the server start with placeholder keys. Never use it for anything other than a local stack.

### 2. Run the app

```bash
cd frontend
flutter pub get
flutter run --dart-define=API_BASE_URL=http://192.168.1.10:8080/api/v1
```

Use the same LAN IP as in `.env`, so a real phone on the same network can reach the server.

For a real iPhone, open `frontend/ios/Runner.xcworkspace` in Xcode once and choose your team under Signing & Capabilities.

### 3. Sign in

Enter any email address. When `RESEND_API_KEY` is empty, the server does not send email. It prints the code in its log instead:

```bash
docker compose logs -f server
```

To try invites, removal or safety numbers, sign in on a second phone or emulator with another email and add each other with your Miuchio IDs.

### Configuration

The server is configured with environment variables. `.env.example` lists the ones Docker Compose uses.

| Variable | Purpose |
| --- | --- |
| `APP_ENV` | `dev` allows placeholder keys and enables test endpoints |
| `DATABASE_URL`, `REDIS_URL`, `PORT` | Set by `docker-compose.yml`. `REDIS_URL` is a `host:port` address |
| `RESEND_API_KEY` | Sends sign-in codes through [Resend](https://resend.com). Empty prints them to the log |
| `MIUCHIO_EMAIL_HMAC_KEY` | Keys the hash that stands in for email addresses. Required outside dev |
| `MIUCHIO_USER_LINK_KEY` | Keys the encrypted link between accounts and album memberships. Required outside dev |
| `S3_ENDPOINT`, `S3_PUBLIC_ENDPOINT` | Storage address for the server, and the one used in links handed to phones |
| `S3_ACCESS_KEY`, `S3_SECRET_KEY`, `S3_BUCKET`, `S3_REGION`, `USE_PATH_STYLE` | Storage credentials and options |

Generate the two Miuchio keys with `openssl rand -base64 32`. Treat them like a database password and never change them on a server with real data: changing either one disconnects every existing account from its albums.

## Tests

```bash
cd server
go vet ./...
go test ./...

cd ../frontend
flutter analyze
flutter test
```

Run `flutter test` from `frontend/`, because the cross-language tests read `../test_vectors/crypto_kat.json`.

Some server tests need a real Postgres and Redis and skip themselves otherwise. They cover the album lock, races and replay, which mocks cannot. To run them, create a separate test database, apply the migrations to it and pass both addresses:

```bash
docker compose up -d postgres redis
docker compose exec -T postgres createdb -U postgres miuchio_test
for f in server/migrations/*.up.sql; do
  docker compose exec -T postgres psql -U postgres -d miuchio_test -v ON_ERROR_STOP=1 -q < "$f"
done

cd server
MIUCHIO_TEST_DATABASE_URL="postgres://postgres:password@localhost:5432/miuchio_test?sslmode=disable" \
MIUCHIO_TEST_REDIS_URL="localhost:6379" \
go test ./...
```

`MIUCHIO_TEST_REDIS_URL` is a `host:port` address, not a `redis://` URL. With the wrong form the Redis tests skip silently.

## Contributing

Bug reports, fixes and ideas are welcome. I am open to changes to the design, theme, UI and UX, and to new features. New features can take a while, because I build Miuchio alone and spend most of my time on the protocol.

Small fixes can go straight to a pull request. For anything bigger, and for any change to the protocol or cryptography, open an issue first so we can agree on the approach. [CONTRIBUTING.md](CONTRIBUTING.md) has the details.

Start with the [website](https://www.miuchio.com) for the design and reasoning behind Miuchio, and ask if anything is unclear.

## Security

If you find a serious security or protocol bug, reach out to me first. [SECURITY.md](SECURITY.md) lists how.

## Get in touch

- **Signal:** `freya.47`, where I am most active
- **Discord:** `freytastic`
- **Email:** [uExistentialist@proton.me](mailto:uExistentialist@proton.me)

I reply fastest on Signal and Discord. Email can take a while.

## License

Miuchio is licensed under the [GNU Affero General Public License v3.0](LICENSE). If you run a modified version of the server for other people, you have to make your changes available to them under the same license.

Miuchio is designed and built by [Freytastic](https://www.freytastic.dev/).
