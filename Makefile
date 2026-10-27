NVIM ?= nvim
DEPS := deps
export XDG_STATE_HOME := $(CURDIR)/.tests/state
export XDG_DATA_HOME := $(CURDIR)/.tests/data
export XDG_CACHE_HOME := $(CURDIR)/.tests/cache

.PHONY: test e2e lint format clean

test: $(DEPS)
	$(NVIM) --headless --noplugin -u tests/minimal_init.lua -c "lua MiniTest.run({ collect = { find_files = function() return vim.fn.globpath('tests', 'test_*.lua', true, true) end } })"

# Real language servers on tests/fixtures; each test skips when its server is missing.
e2e: $(DEPS)
	$(NVIM) --headless --noplugin -u tests/minimal_init.lua -c "lua MiniTest.run({ collect = { find_files = function() return vim.fn.globpath('tests/e2e', 'test_*.lua', true, true) end } })"

lint:
	stylua --check lua plugin tests bench

format:
	stylua lua plugin tests bench

$(DEPS): $(DEPS)/mini.nvim $(DEPS)/snacks.nvim

$(DEPS)/mini.nvim:
	git clone --depth 1 https://github.com/nvim-mini/mini.nvim $@

$(DEPS)/snacks.nvim:
	git clone --depth 1 https://github.com/folke/snacks.nvim $@

clean:
	rm -rf $(DEPS) .tests
