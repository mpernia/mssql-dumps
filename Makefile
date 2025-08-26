# Makefile for MSSQL Dumps Tool

SHELL := /bin/bash
DOCKER_COMPOSE = docker-compose
OUTPUT_DIR = ./output
SCRIPT = ./mssql_backup.sh

ifneq (,$(wildcard ./.env))
    include .env
    export
    ENV_FILE_EXISTS = true
else
    ENV_FILE_EXISTS = false
endif

.PHONY: help
help:
	@echo "MSSQL Azure Backup Tool"
	@echo ""
	@echo "Targets:"
	@echo "  help           - Show this help message"
	@echo "  build          - Build Docker image"
	@echo "  run            - Run backup script with Docker"
	@echo "  run-local      - Run backup script locally"
	@echo "  setup-env      - Create .env file from .env-example"
	@echo "  clean          - Remove all generated SQL files"
	@echo "  clean-docker   - Remove Docker containers and images"
	@echo ""
	@echo "Options:"
	@if [ "$(ENV_FILE_EXISTS)" = "true" ]; then \
		echo "  Using .env file for configuration."; \
	else \
		echo "  No .env file found. Run 'make setup-env' to create one or use ARGS."; \
	fi
	@echo ""
	@echo "Examples:"
	@echo "  make build"
	@echo "  make run                    # Uses environment variables from .env file"
	@echo "  make run ARGS=\"-S server.database.windows.net -d database -U username -P password\""
	@echo "  make run-local              # Uses environment variables from .env file"
	@echo "  make run-local ARGS=\"-S server.database.windows.net -d database -U username -P password\""
	@echo ""

.PHONY: build
build:
	@echo "Building Docker image..."
	@$(DOCKER_COMPOSE) build

.PHONY: run
run:
	@mkdir -p $(OUTPUT_DIR)
	@if [ -z "$(ARGS)" ]; then \
		if [ "$(ENV_FILE_EXISTS)" = "true" ]; then \
			echo "Running backup script in Docker using environment variables"; \
			$(DOCKER_COMPOSE) run --rm mssql-backup bash -c "./mssql_backup.sh"; \
		else \
			echo "Error: No arguments provided and no .env file found."; \
			echo "Either:"; \
			echo "  1. Use ARGS=\"-S server -d database -U username -P password\" or"; \
			echo "  2. Run 'make setup-env' to create a .env file"; \
			exit 1; \
		fi; \
	else \
		echo "Running backup script in Docker with arguments: $(ARGS)"; \
		$(DOCKER_COMPOSE) run --rm mssql-backup bash -c "./mssql_backup.sh $(ARGS)"; \
	fi

.PHONY: run-local
run-local:
	@mkdir -p $(OUTPUT_DIR)
	@chmod +x $(SCRIPT)
	@if [ -z "$(ARGS)" ]; then \
		if [ "$(ENV_FILE_EXISTS)" = "true" ]; then \
			echo "Running backup script locally using environment variables"; \
			$(SCRIPT); \
		else \
			echo "Error: No arguments provided and no .env file found."; \
			echo "Either:"; \
			echo "  1. Use ARGS=\"-S server -d database -U username -P password\" or"; \
			echo "  2. Run 'make setup-env' to create a .env file"; \
			exit 1; \
		fi; \
	else \
		echo "Running backup script locally with arguments: $(ARGS)"; \
		$(SCRIPT) $(ARGS); \
	fi

.PHONY: clean
clean:
	@echo "Cleaning SQL files..."
	@rm -f *.sql
	@rm -f $(OUTPUT_DIR)/*.sql
	@echo "Done."

.PHONY: clean-docker
clean-docker:
	@echo "Cleaning Docker resources..."
	@$(DOCKER_COMPOSE) down --rmi local
	@echo "Done."

.PHONY: setup-env
setup-env:
	@if [ -f ".env" ]; then \
		echo "Warning: .env file already exists. Rename or delete it first if you want to recreate it."; \
	else \
		if [ -f ".env-example" ]; then \
			cp .env-example .env; \
			echo "Created .env file from .env-example. Please edit it with your settings."; \
			echo "Then run 'make run' or 'make run-local' without additional arguments."; \
		else \
			echo "Error: .env-example file not found."; \
			exit 1; \
		fi; \
	fi

$(OUTPUT_DIR):
	@mkdir -p $(OUTPUT_DIR)
