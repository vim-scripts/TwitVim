" ==============================================================
" TwitVim - Post to Twitter from Vim
" Language: Vim Script
" Maintainer: Po Shan Cheah <morton@mortonfox.com>
" Based on Twitter Vim script by Travis Jeffery <eatsleepgolf@gmail.com>
" Created: March 28, 2008
" Last updated: April 1, 2008
" ==============================================================

" Load this module only once.
if exists('loaded_twitvim')
    finish
endif
let loaded_twitvim = 1

let s:proxy = ""
let s:login = ""

" The extended character limit is 246. Twitter will display a tweet longer than
" 140 characters in truncated form with a link to the full tweet. If that is
" undesirable, set s:char_limit to 140.
let s:char_limit = 246

let s:twupdate = "http://twitter.com/statuses/update.xml?source=vim"

" Get user-config variables twitvim_proxy and twitvim_login.
function! s:get_config()
    " Get proxy setting from twitvim_proxy in .vimrc or _vimrc.
    " Format is proxysite:proxyport
    if exists('g:twitvim_proxy')
	let s:proxy = "-x " . g:twitvim_proxy
    else
	let s:proxy = ""
    endif

    " Get Twitter login info from twitvim_login in .vimrc or _vimrc.
    " Format is username:password
    if exists('g:twitvim_login')
	let s:login = "-u " . g:twitvim_login
    else
	" Beep and error-highlight 
	execute "normal \<Esc>"
	echohl ErrorMsg
	echomsg 'Twitter login not set. Please add to .vimrc: let twitvim_login="USER:PASS"'
	echohl None
	return -1
    endif
    return 0
endfunction

" Common code to post a message to Twitter.
function! s:post_twitter(mesg)
    " Get user-config variables twitvim_proxy and twitvim_login.
    " We get these variables every time before posting to Twitter so that the
    " user can change them on the fly.
    let rc = s:get_config()
    if rc < 0
	return -1
    endif

    let mesg = a:mesg

    " Remove trailing newline. You see that when you visual-select an entire
    " line. Don't let it count towards the tweet length.
    let mesg = substitute(mesg, '\n$', '', "")

    " Convert internal newlines to spaces.
    let mesg = substitute(mesg, '\n', ' ', "g")

    " Check tweet length. Note that the tweet length should be checked before
    " URL-encoding the special characters because URL-encoding increases the
    " string length.
    if strlen(mesg) > s:char_limit
	echohl WarningMsg
	echo "Your tweet has" strlen(mesg) - s:char_limit "too many characters. It was not sent."
	echohl None
    elseif strlen(mesg) < 1
	echohl WarningMsg
	echo "Your tweet was empty. It was not sent."
	echohl None
    else
	" URL-encode some special characters so they show up verbatim.
	let mesg = substitute(mesg, '%', '%25', "g")
	let mesg = substitute(mesg, '"', '%22', "g")
	let mesg = substitute(mesg, '&', '%26', "g")

	let output = system("curl ".s:proxy." ".s:login.' -d status="'.mesg.'" '.s:twupdate)
	if v:shell_error != 0
	    echohl ErrorMsg
	    echomsg "Error posting your tweet. Result code: ".v:shell_error
	    echomsg "Output:"
	    echomsg output
	    echohl None
	else
	    echo "Your tweet was sent. You used" strlen(mesg) "characters."
	endif
    endif
endfunction

function! s:CmdLine_Twitter()
    " Do this here too to check for twitvim_login. This is to avoid having the
    " user type in the message only to be told that his configuration is
    " incomplete.
    let rc = s:get_config()
    if rc < 0
	return -1
    endif

    call inputsave()
    let mesg = input("Your Twitter: ")
    call inputrestore()
    call s:post_twitter(mesg)
endfunction

" Prompt user for tweet.
command! PosttoTwitter :call <SID>CmdLine_Twitter()

" Post current line to Twitter.
command! CPosttoTwitter :call <SID>post_twitter(getline('.'))

" Post entire buffer to Twitter.
command! BPosttoTwitter :call <SID>post_twitter(join(getline(1, "$")))

" Post visual selection to Twitter.
vmap T y:call <SID>post_twitter(@")<cr>

" vim:set tw=0:
