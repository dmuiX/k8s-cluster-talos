# Vim Setup for Kubernetes/YAML Development

## Prerequisites

### 1. Install Required Tools

```bash
# Install Node.js (required for yaml-language-server)
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt-get install -y nodejs

# Install yaml-language-server
sudo npm install -g yaml-language-server

# Install kubeconform for validation
wget -qO- https://github.com/yannh/kubeconform/releases/latest/download/kubeconform-linux-amd64.tar.gz | tar xz
sudo mv kubeconform /usr/local/bin/

# Install kubectl (if not already)
# curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
# sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
```

## Plugin Manager

Choose one:

### Option A: vim-plug (Recommended - Simple)
```bash
curl -fLo ~/.vim/autoload/plug.vim --create-dirs \
    https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim
```

### Option B: Vundle
```bash
git clone https://github.com/VundleVim/Vundle.vim.git ~/.vim/bundle/Vundle.vim
```

## Add to Your .vimrc

Add this section to your existing `~/.vimrc`:

```vim
" ============================================================================
" Kubernetes/YAML Configuration
" ============================================================================

" --- Plugin Manager (vim-plug) ---
call plug#begin('~/.vim/plugged')

" LSP Support
Plug 'prabirshrestha/vim-lsp'
Plug 'mattn/vim-lsp-settings'
Plug 'prabirshrestha/asyncomplete.vim'
Plug 'prabirshrestha/asyncomplete-lsp.vim'

" YAML Support
Plug 'stephpy/vim-yaml'
Plug 'pedrohdz/vim-yaml-folds'

" Kubernetes specific
Plug 'andrewstuart/vim-kubernetes'

" File tree (optional but useful)
Plug 'preservim/nerdtree'

" Syntax checking
Plug 'dense-analysis/ale'

" Status line (optional)
Plug 'vim-airline/vim-airline'

call plug#end()

" --- LSP Configuration ---
" Auto-configure yaml-language-server
let g:lsp_settings = {
\   'yaml-language-server': {
\     'workspace_config': {
\       'yaml': {
\         'schemas': {
\           'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/helm.toolkit.fluxcd.io/helmrelease_v2.json': ['**/infra/controller/*.yml', '**/apps/*.yml'],
\           'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/kustomize.toolkit.fluxcd.io/kustomization_v1.json': ['**/clusters/*/flux-system/*.yaml'],
\           'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/source.toolkit.fluxcd.io/gitrepository_v1.json': ['**/clusters/*/flux-system/*.yaml']
\         },
\         'customTags': [
\           '!encrypted/pkcs1-oaep scalar',
\           '!vault scalar'
\         ],
\         'validate': v:true,
\         'hover': v:true,
\         'completion': v:true
\       }
\     }
\   }
\}

" Enable LSP on YAML files
augroup lsp_yaml
    autocmd!
    autocmd FileType yaml setlocal omnifunc=lsp#complete
    autocmd FileType yaml nmap <buffer> gd <plug>(lsp-definition)
    autocmd FileType yaml nmap <buffer> gr <plug>(lsp-references)
    autocmd FileType yaml nmap <buffer> K <plug>(lsp-hover)
augroup END

" --- ALE Configuration (Linting) ---
let g:ale_linters = {
\   'yaml': ['yamllint', 'kubeconform'],
\}

let g:ale_fixers = {
\   'yaml': ['prettier'],
\}

" ALE settings
let g:ale_fix_on_save = 0
let g:ale_lint_on_text_changed = 'normal'
let g:ale_lint_on_insert_leave = 1

" Configure kubeconform for ALE
let g:ale_yaml_kubeconform_options = '-strict -ignore-missing-schemas -schema-location default -schema-location "https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json"'

" --- YAML Settings ---
autocmd FileType yaml setlocal ts=2 sts=2 sw=2 expandtab
autocmd FileType yaml setlocal indentkeys-=<:>

" Enable folding for YAML
autocmd FileType yaml setlocal foldmethod=indent
autocmd FileType yaml setlocal foldlevel=2

" --- Key Mappings ---
" Validate current file with kubeconform
nnoremap <leader>kv :!kubeconform -strict -ignore-missing-schemas -schema-location default -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' %<CR>

" Apply to cluster (dry-run)
nnoremap <leader>ka :!kubectl apply --dry-run=server -f %<CR>

" Show kubectl explain
nnoremap <leader>ke :execute '!kubectl explain ' . expand('<cword>')<CR>

" Toggle NERDTree
nnoremap <leader>n :NERDTreeToggle<CR>

" ALE next/previous error
nmap <silent> [e <Plug>(ale_previous_wrap)
nmap <silent> ]e <Plug>(ale_next_wrap)

" ============================================================================
```

## Installation Steps

1. **Add the configuration above to your `.vimrc`**

2. **Install plugins:**
   ```bash
   # Open vim and run:
   vim +PlugInstall +qall
   ```

3. **Install LSP servers:**
   ```bash
   # The vim-lsp-settings plugin will prompt to install servers automatically
   # Or manually install:
   npm install -g yaml-language-server
   ```

4. **Create ALE linter wrapper for kubeconform** (optional):
   ```bash
   mkdir -p ~/.vim/ale_linters/yaml
   cat > ~/.vim/ale_linters/yaml/kubeconform.vim << 'EOF'
call ale#linter#Define('yaml', {
\   'name': 'kubeconform',
\   'output_stream': 'both',
\   'executable': 'kubeconform',
\   'command': 'kubeconform -strict -ignore-missing-schemas -schema-location default -schema-location "https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json" %t',
\   'callback': 'ale#handlers#unix#HandleAsError',
\})
EOF
   ```

## Key Mappings Reference

- `<leader>kv` - Validate current file with kubeconform
- `<leader>ka` - Apply to cluster (dry-run)
- `<leader>ke` - Show kubectl explain for word under cursor
- `<leader>n` - Toggle file tree
- `gd` - Go to definition
- `gr` - Show references
- `K` - Show hover documentation
- `[e` / `]e` - Previous/Next error

## Testing

1. Open a Kubernetes YAML file:
   ```bash
   vim ~/fluxcd.k8sdev.cloud/infra/controller/cert-manager.yml
   ```

2. Check if LSP is working:
   - Place cursor on a property and press `K` (should show documentation)
   - Type to trigger autocomplete

3. Validate the file:
   - Press `<leader>kv` to run kubeconform

## Advantages Over VS Code

✅ No caching issues - restart is instant
✅ Configurable schema locations
✅ Direct integration with kubectl
✅ Lightweight and fast
✅ Works over SSH
✅ No GUI overhead

## Troubleshooting

### LSP not working
```bash
:LspStatus
:LspInstallServer yaml-language-server
```

### Check ALE linters
```vim
:ALEInfo
```

### Reset everything
```bash
rm -rf ~/.vim/plugged
rm -rf ~/.cache/vim-lsp
vim +PlugInstall +qall
```
