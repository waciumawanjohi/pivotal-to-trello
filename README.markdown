# Pivotal-to-Trello

This CLI exports stories from a [Pivotal Tracker](https://www.pivotaltracker.com/) project and converts them to cards in a [Trello](https://trello.com/) board. It is a fork of [Dave Perrett's pivotal-to-trello](https://github.com/recurser/pivotal-to-trello) with a number of [improvements for users](#improvements-from-fork).

## Installation

The program is packaged as a Docker container.

## Usage

### Presteps

1. Obtain your API credentials from Trello and Pivotal Tracker.

<details>

<summary>Obtaining API credentials</summary>

## Obtaining API credentials

### Pivotal Tracker

The Pivotal Tracker token can be found at the bottom of your [Pivotal profile page](https://www.pivotaltracker.com/profile).

### Trello

There are two methods for obtaining the Trello API key and token. The difference may be the age of the Trello account.
If you visit https://trello.com/1/appKey/generate and are redirected to https://trello.com/app-key, then use Method 2. Otherwise, Method 1 is appropriate.

<details>

<summary>Method 1</summary>

1. Login into Trello
2. Visit [https://trello.com/1/appKey/generate](https://trello.com/1/appKey/generate). Your 32-character application key will be listed in the first box.
3. To obtain your Trello member token, visit the following URL, substuting your Trello application key for *APP_KEY*: [https://trello.com/1/authorize?key=APP_KEY&name=Pivotal%20To%20Trello&response_type=token&scope=read,write](https://trello.com/1/authorize?key=APP_KEY&name=Pivotal%20To%20Trello&response_type=token&scope=read,write)
4. Click the *Allow* button, and you will be presented with a 64-character token.

See the [Trello documentation](https://trello.com/docs/gettingstarted/index.html#getting-an-application-key) for more details.

</details>
<details>

<summary>Method 2</summary>

1. Login into Trello
2. Visit https://trello.com/power-ups/admin/
3. Acknowledge developer terms
4. Click "New" in _Power-Ups and Integrations_
5. Fill in the form. Suggested values:
  - Power-Up Name: Pivotal-to-Trello
  - Workspace: _The name of the workspace containing your target board_
  - Iframe connector URL: _Skip_
  - Email: _Your email_
  - Support Contact: _Your email_
  - Author: _Your name_
6. Click "Generate a new API key"
7. Copy the **API KEY**
8. Click generate a "Token"
9. Click "Allow"
10. Copy the **Token**

</details>

</details>

2. Create a Trello Board that you will import into.
3. [Add members](https://support.atlassian.com/trello/docs/adding-people-to-a-board/) to your Trello board. E.g. if your Pivotal Tracker project has stories owned by F. Rogers and L. Burton, ensure those individuals create accounts on Trello and are members of your new board.
4. Set environment variables for your credentials

```
 export TRELLO_KEY=
 export TRELLO_TOKEN=
 export PIVOTAL_TOKEN=
```

### Run with defaults (recommended)

`Default` will:

- Clear all of the cards and lists from your chosen board.
- Create the following lists: Icebox, Backlog, Started, Finished, Delivered, Rejected, Accepted, Will Not Do
- For each Tracker story, create a card in the respective lists.

Run the container, passing in the `default` flag:

```sh
docker run -i waciumawanjohi/pivotal-to-trello:latest import --trello-key $TRELLO_KEY --trello-token $TRELLO_TOKEN --pivotal-token $PIVOTAL_TOKEN --default
```

The program will ask you to:

- Identify the target Tracker Project and Trello Board
- Confirm deletion of the current lists and cards
- Map the Tracker Project Owners to Trello Members

### Run without defaults

<details>

<summary>Run without defaults</summary>

Running without default will not create any lists. Create your own desired lists in the Trello Board before running.

Run the container:

```sh
docker run -i waciumawanjohi/pivotal-to-trello:latest import --trello-key $TRELLO_KEY --trello-token $TRELLO_TOKEN --pivotal-token $PIVOTAL_TOKEN
```

The program will ask you to:

- Identify the target Tracker Project and Trello Board
- Identify which list stories in Accepted, Finished, etc. belong
- Choose label colors for different labels
- Confirm deletion of the current lists and cards
- Map the Tracker Persons to Trello Members

After all stories have been imported, the program will allow you to review existing cards that were not imported. You can choose to keep or delete these.

If your run is interrupted and you know the ID of your last imported story, you can run with the resume-at flag and the story ID:

```sh
docker run -i waciumawanjohi/pivotal-to-trello:latest import --trello-key $TRELLO_KEY --trello-token $TRELLO_TOKEN --pivotal-token $PIVOTAL_TOKEN resume-at 188000000
```

---

</details>

## Improvements from fork

This project improves upon its base in the following ways:

- Created Trello cards have members assigned, corresponding to the Tracker story owners
- Cards are created in their story's current Tracker order (rather than in story creation order)
- Cards are created with the labels from the Tracker story
- Cards are created with a label for the story's points estimation
- Users can choose a default configuration. Does not require users to precreate lists or manually map them to story states
- Users can restart imports with `--resume-at` flag
- Users are notified of cards present in the board that were not imported from Tracker
- Will update the Trello cards with new changes in the Tracker stories
- Progress bars display work done and estimated time remaining

## License

This project is licensed under AGPL by Waciuma Wanjohi.
It is a modification of an MIT licensed project by Dave Perrett.

Both licenses can be found in the [License file](./LICENSE).
