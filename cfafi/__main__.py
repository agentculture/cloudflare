"""Allow ``python -m cfafi`` to invoke the CLI."""

from cfafi.cli import main

if __name__ == "__main__":
    raise SystemExit(main())
