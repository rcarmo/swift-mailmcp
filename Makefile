.DEFAULT_GOAL := start

.PHONY: help build start run daemon status authorize test smoke logs

help:
	@printf '%s\n' \
	  'make [start]  Start the signed app if needed and check its MCP endpoint' \
	  'make status   Check the authenticated MCP endpoint without reading mail' \
	  'make build    Build and sign (requires MAILMCP_SIGN_IDENTITY)' \
	  'make authorize  Request Mail Automation permission' \
	  'make test     Run Swift tests' \
	  'make smoke    Run isolated HTTP smoke checks against the signed app' \
	  'make logs     Stream MailMCP diagnostics'

build:
	@scripts/build-app.sh

dist/MailMCP.app/Contents/MacOS/MailMCP:
	@$(MAKE) build

start: dist/MailMCP.app/Contents/MacOS/MailMCP
	@python3 scripts/service.py start

run daemon: start

status:
	@python3 scripts/service.py status

authorize: dist/MailMCP.app/Contents/MacOS/MailMCP
	@open -n -W -a "$(CURDIR)/dist/MailMCP.app" --args --authorize-mail

test:
	swift test

smoke: dist/MailMCP.app/Contents/MacOS/MailMCP
	@scripts/smoke-http.sh

logs:
	@log stream --style compact --predicate 'subsystem == "net.rcarmo.mailmcp"'
