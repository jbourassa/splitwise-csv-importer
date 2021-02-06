# Splitwise CSV Importer

Imports CSV files into Splitwise. Nothing fancy but beats doing it by hand.

Each line of the CSV is an expense coming out of your pocket, and get split evenly with your friend.

The CSV file must have the following headers:
- `amount`
- `description`
- `date` (ISO8601)
- `comment`
- `split` (`n` means do not split)

## Setup

Register a [Splitwise app](https://secure.splitwise.com/apps) to get your credentials. Figure out your user id, your friend's user id and the group id to add expenses in, and fill the `.env` file with those value (`cp .env .env.template`). Once you're ready, run:

```
FILENAME=/path/to/file.csv ./splitwise-csv-import.rb
```
