"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
" => General
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
syntax on                                   "syntax highlighting
filetype indent plugin on                   "indent based on filtype and load plugins
set autoindent                              "auto indent based on previous line
set smartindent                             "smart indenting based on language
set vb t_vb=                                "no visual bell
set nocompatible                            "don't emulate vi bugs
set backspace=2                             "allow backspacing over special things
set tabstop=4                               "4 space tabs
set softtabstop=4                           "4 space tabs even while editing
set shiftwidth=4                            "number of spaces to use for (auto)indent
set expandtab                               "expand tabs to spaces
set incsearch                               "search while entering terms
set autoread                                "read in changes from outside alterations
set ignorecase                              "ignore case while searching
set showmatch                               "show matching brackets
set smarttab                                "insert blanks in front of a line
set scrolloff=10                            " keep the cursor centered in the screen
set tw=78                                   "78 character line lengths
set fo=cq                                   "rewrap to 78
set wm=0                                    "don't wrap based on terminal

"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
" => Appearance
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
set t_Co=256                                "make sure we're 256 color
set background=dark                         "dark background
set laststatus=2                            "always show status
set ruler                                   "display cursor position info in bottom right
set number                                  "line numbers on the left
colorscheme gruvbox

" Format the statusline
set statusline=\ %{HasPaste()}%F%m%r%h\ %w\ \ CWD:\ %r%{CurDir()}%h\ \ \ Line:\ %l/%L:%c\

function! CurDir()
    let curdir = substitute(getcwd(), '/Users/arollyson/', "~/", "g")
    return curdir
endfunction

function! HasPaste()
    if &paste
        return 'PASTE MODE  '
    else
        return ''
    endif
endfunction

"highlight chars past 78 length
"augroup vimrc_autocmds
"  autocmd BufEnter * highlight OverLength ctermbg=darkgrey guibg=#592929
"  autocmd BufEnter * match OverLength /\%78v.*/
"augroup END

""""""""""""""""""""""""""""""""""""""""""""""""""""""
" => Keybindings
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""

" With a map leader it's possible to do extra key combinations
" like <leader>w saves the current file
let mapleader = ","
let g:mapleader = ","

"get rid of line numbers
nmap <f1> :set number! number?<cr> 

"go into paste mode
nmap <f2> :set paste! paste?<cr>            

"the forgot to sudo key combo
cmap w!! w !sudo tee %

"toggle spellchecking
map <leader>ss :setlocal spell!<cr>

"move display lines, ignore wrapped lines
nmap <silent> j gj
nmap <silent> k gk
