.PHONY: all check lint format test clean run

# Default target: Run all checks
all: format lint test

# Fast compilation check
check:
	cargo check

# Linting with Clippy (Treat warnings as errors to ensure high quality)
lint:
	cargo clippy -- -D warnings

# Format code
format:
	cargo fmt

# Run tests
test:
	cargo test

# Clean build artifacts
clean:
	cargo clean

# Run the server locally
run:
	YATA_SECRET=dev-secret cargo run
