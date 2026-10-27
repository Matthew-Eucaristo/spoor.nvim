NVIM ?= nvim
DEPS := deps
export XDG_STATE_HOME := $(CURDIR)/.tests/state
export XDG_DATA_HOME := $(CURDIR)/.tests/data
export XDG_CACHE_HOME := $(CURDIR)/.tests/cache

.PHONY: test e2e smoke lint format clean

test: $(DEPS)
	$(NVIM) --headless --noplugin -u tests/minimal_init.lua -c "lua MiniTest.run({ collect = { find_files = function() return vim.fn.globpath('tests', 'test_*.lua', true, true) end } })"

# Real language servers on tests/fixtures; each test skips when its server is missing.
e2e: $(DEPS)
	$(NVIM) --headless --noplugin -u tests/minimal_init.lua -c "lua MiniTest.run({ collect = { find_files = function() return vim.fn.globpath('tests/e2e', 'test_*.lua', true, true) end } })"

# spoor in real configs (minimal, plain lazy.nvim, stock LazyVim) on $(NVIM)
smoke: $(DEPS)
	for c in minimal lazy lazyvim; do NVIM=$(NVIM) tests/smoke/run.sh $$c || exit 1; done

lint:
	stylua --check lua plugin tests bench lazy.lua

format:
	stylua lua plugin tests bench lazy.lua

$(DEPS): $(DEPS)/mini.nvim $(DEPS)/snacks.nvim

$(DEPS)/mini.nvim:
	git clone --depth 1 https://github.com/nvim-mini/mini.nvim $@

$(DEPS)/snacks.nvim:
	git clone --depth 1 https://github.com/folke/snacks.nvim $@

clean:
	rm -rf $(DEPS) .tests
