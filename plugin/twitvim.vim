" ==============================================================
" TwitVim - Post to Twitter from Vim
" Based on Twitter Vim script by Travis Jeffery <eatsleepgolf@gmail.com>
"
" Version: 0.2.5
" License: Vim license. See :help license
" Language: Vim script
" Maintainer: Po Shan Cheah <morton@mortonfox.com>
" Created: March 28, 2008
" Last updated: April 14, 2008
"
" GetLatestVimScripts: 2204 1 twitvim.vim
" ==============================================================

" Load this module only once.
if exists('loaded_twitvim')
    finish
endif
let loaded_twitvim = 1

" Avoid side-effects from cpoptions setting.
let s:save_cpo = &cpo
set cpo&vim

let s:proxy = ""
let s:login = ""

" If true, disable the Perl code that simplifies and localizes Twitter
" timestamps.
if !exists('g:twitvim_disable_simple_time')
    let g:twitvim_disable_simple_time = 0
endif

" The extended character limit is 246. Twitter will display a tweet longer than
" 140 characters in truncated form with a link to the full tweet. If that is
" undesirable, set s:char_limit to 140.
let s:char_limit = 246

let s:twupdate = "http://twitter.com/statuses/update.xml?source=twitvim"

function! s:get_config_proxy()
    " Get proxy setting from twitvim_proxy in .vimrc or _vimrc.
    " Format is proxysite:proxyport
    let s:proxy = exists('g:twitvim_proxy') ? "-x " . g:twitvim_proxy : ""
endfunction

" Get user-config variables twitvim_proxy and twitvim_login.
function! s:get_config()
    call s:get_config_proxy()

    " Get Twitter login info from twitvim_login in .vimrc or _vimrc.
    " Format is username:password
    if exists('g:twitvim_login') && g:twitvim_login != ''
	let s:login = "-u " . g:twitvim_login
    else
	" Beep and error-highlight 
	execute "normal \<Esc>"
	echohl ErrorMsg
	echomsg 'Twitter login not set.'
	    \ 'Please add to .vimrc: let twitvim_login="USER:PASS"'
	echohl None
	return -1
    endif
    return 0
endfunction

" === XML helper functions ===

" Get the content of the n'th element in a series of elements.
function! s:xml_get_nth(xmlstr, elem, n)
    let matchres = matchlist(a:xmlstr, '<'.a:elem.'>\(.\{-}\)</'.a:elem.'>', -1, a:n)
    return matchres == [] ? "" : matchres[1]
endfunction

" Get the content of the specified element.
function! s:xml_get_element(xmlstr, elem)
    return s:xml_get_nth(a:xmlstr, a:elem, 1)
endfunction

" Remove any number of the specified element from the string. Used for removing
" sub-elements so that you can parse the remaining elements safely.
function! s:xml_remove_elements(xmlstr, elem)
    return substitute(a:xmlstr, '<'.a:elem.'>.\{-}</'.a:elem.'>', '', "g")
endfunction

" === XML helper functions ===

" === Perl time string parser ===

if has('perl') && !g:twitvim_disable_simple_time
    function s:def_perl_time_funcs()
	perl <<EOF
use Time::Local;
use POSIX qw(strftime);

# Convert abbreviated month name to month number.
sub twitvim_conv_month {
    my $monthstr = shift;
    my @months = qw(jan feb mar apr may jun jul aug sep oct nov dec);
    for my $mon (0..11) {
	$months[$mon] eq lc($monthstr) and return $mon;
    }
    undef;
}

# Parse time string in Twitter format.
sub twitvim_parse_time {
    my $timestr = shift;
    # This timestamp format is used by Twitter in timelines.
    if ($timestr =~ /^\w+,\s+(\d+)\s+(\w+)\s+(\d+)\s+(\d+):(\d+):(\d+)\s+\+0000$/) {
	my $mon = twitvim_conv_month($2);
	defined $mon or return undef;
	return timegm($6, $5, $4, $1, $mon, $3);
    }
    # This timestamp format is used by Twitter in response to an update.
    elsif ($timestr =~ /^\w+\s+(\w+)\s+(\d+)\s+(\d+):(\d+):(\d+)\s+\+0000\s+(\d+)$/) {
	my $mon = twitvim_conv_month($1);
	defined $mon or return undef;
	return timegm($5, $4, $3, $2, $mon, $6);
    }
    else {
	return undef;
    }
}

# Convert the Twitter timestamp to local time and simplify it.
sub twitvim_new_time {
    my $timestr = shift;
    my $time = twitvim_parse_time($timestr);
    defined $time ? strftime("%I:%M %p %b %d, %Y", localtime($time)) : $timestr;
}
EOF
    endfunction

    call s:def_perl_time_funcs()

    " Wrapper for the Twitter timestamp converter.
    function s:perl_time(timestr)
	execute 'perl VIM::DoCommand("let newtime = \"".twitvim_new_time("'.a:timestr.'")."\"")'
	return newtime
    endfunction
endif

" Simplify the time string. Do this only if the Perl interface is enabled and
" if we have not disabled the feature.
function s:time_filter(timestr)
    let s = a:timestr
    if has('perl') && !g:twitvim_disable_simple_time
	let s = s:perl_time(s)
    endif
    return s
endfunction

" === Perl time string parser ===

" Add update to Twitter buffer if public, friends, or user timeline.
function! s:add_update(output)
    if s:twit_buftype == "public" || s:twit_buftype == "friends" || s:twit_buftype == "user"

	" Parse the output from the Twitter update call.
	let date = s:time_filter(s:xml_get_element(a:output, 'created_at'))
	let text = s:xml_get_element(a:output, 'text')
	let name = s:xml_get_element(a:output, 'screen_name')

	if text == ""
	    return
	endif

	let twit_bufnr = bufwinnr('^'.s:twit_winname.'$')
	if twit_bufnr > 0
	    execute twit_bufnr . "wincmd w"
	    call append(2, name.': '.s:convert_entity(text).' |'.date.'|')
	    wincmd p
	endif
    endif
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
	echo "Your tweet has" strlen(mesg) - s:char_limit
	    \ "too many characters. It was not sent."
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
	let mesg = substitute(mesg, '+', '%2B', "g")

	let output = system("curl -s ".s:proxy." ".s:login.' -d status="'.
		    \mesg.'" '.s:twupdate)
	if v:shell_error != 0
	    echohl ErrorMsg
	    echomsg "Error posting your tweet. Result code: ".v:shell_error
	    echomsg "Output:"
	    echomsg output
	    echohl None
	else
	    call s:add_update(output)
	    echo "Your tweet was sent. You used" strlen(mesg) "characters."
	endif
    endif
endfunction

" Prompt user for tweet and then post it.
" If initstr is given, use that as the initial input.
function! s:CmdLine_Twitter(initstr)
    " Do this here too to check for twitvim_login. This is to avoid having the
    " user type in the message only to be told that his configuration is
    " incomplete.
    let rc = s:get_config()
    if rc < 0
	return -1
    endif

    call inputsave()
    let mesg = input("Your Twitter: ", a:initstr)
    call inputrestore()
    call s:post_twitter(mesg)
endfunction

" This is for a local mapping in the timeline. Start an @-reply on the command
" line to the author of the tweet on the current line.
function! s:Quick_Reply()
    let matchres = matchlist(getline('.'), '^\(\w\+\):')
    if matchres != []
	call s:CmdLine_Twitter('@'.matchres[1].' ')
    endif
endfunction

" Prompt user for tweet.
if !exists(":PosttoTwitter")
    command PosttoTwitter :call <SID>CmdLine_Twitter('')
endif

" Post current line to Twitter.
if !exists(":CPosttoTwitter")
    command CPosttoTwitter :call <SID>post_twitter(getline('.'))
endif

" Post entire buffer to Twitter.
if !exists(":BPosttoTwitter")
    command BPosttoTwitter :call <SID>post_twitter(join(getline(1, "$")))
endif

" Post visual selection to Twitter.
noremap <SID>Visual y:call <SID>post_twitter(@")<cr>
noremap <unique> <script> <Plug>TwitvimVisual <SID>Visual
if !hasmapto('<Plug>TwitvimVisual')
    vmap <unique> <A-t> <Plug>TwitvimVisual
endif

" Decode HTML entities. Twitter gives those to us a little weird. For example,
" a '<' character comes to us as &amp;lt;
function! s:convert_entity(str)
    let s = a:str
    let s = substitute(s, '&amp;', '\&', 'g')
    let s = substitute(s, '&lt;', '<', 'g')
    let s = substitute(s, '&gt;', '>', 'g')
    let s = substitute(s, '&#\(\d\+\);','\=nr2char(submatch(1))', 'g')
    return s
endfunction

let s:twit_winname = "Twitter_".localtime()
let s:twit_buftype = ""

" Switch to the Twitter window if there is already one or open a new window for
" Twitter.
function! s:twitter_win()
    let twit_bufnr = bufwinnr('^'.s:twit_winname.'$')
    if twit_bufnr > 0
	execute twit_bufnr . "wincmd w"
    else
	execute "new " . s:twit_winname
	setlocal noswapfile
	setlocal buftype=nofile
	setlocal bufhidden=delete 
	setlocal foldcolumn=0
	setlocal nobuflisted
	setlocal nospell

	" Quick reply feature for replying from the timeline.
	nnoremap <buffer> <silent> <A-r> :call <SID>Quick_Reply()<cr>

	" Beautify the Twitter window with syntax highlighting.
	if has("syntax") && exists("g:syntax_on") && !has("syntax_items")

	    " Twitter user name: from start of line to first colon.
	    syntax match twitterUser /^.\{-1,}:/

	    " Use the bars to recognize the time but hide the bars.
	    syntax match twitterTime /|[^|]\+|$/ contains=twitterTimeBar
	    syntax match twitterTimeBar /|/ contained

	    " Use the extra star at the end to recognize the title but hide the
	    " star.
	    syntax match twitterTitle /^.\+\*$/ contains=twitterTitleStar
	    syntax match twitterTitleStar /\*$/ contained

	    " Highlight links in tweets.
	    syntax match twitterLink "\<http://\S\+"
	    syntax match twitterLink "\<https://\S\+"
	    syntax match twitterLink "\<ftp://\S\+"

	    " An @-reply must be preceded by whitespace and ends at a non-word
	    " character.
	    syntax match twitterReply "\S\@<!@\w\+"

	    highlight default link twitterUser Identifier
	    highlight default link twitterTime String
	    highlight default link twitterTimeBar Ignore
	    highlight default link twitterTitle Title
	    highlight default link twitterTitleStar Ignore
	    highlight default link twitterLink Underlined
	    highlight default link twitterReply Label
	endif
    endif
endfunction

" Get a Twitter window and stuff text into it.
function! s:twitter_wintext(text)
    call s:twitter_win()

    " Overwrite the entire buffer.
    " Need to use 'silent' or a 'No lines in buffer' message will appear.
    silent %delete
    call setline('.', a:text)
    normal 1G

    wincmd p
endfunction

" Show a timeline.
function! s:show_timeline(timeline)
    let matchcount = 1
    let text = []

    let channel = s:xml_remove_elements(a:timeline, 'item')
    let title = s:xml_get_element(channel, 'title')

    " The extra stars at the end are for the syntax highlighter to recognize
    " the title. Then the syntax highlighter hides the stars by coloring them
    " the same as the background. It is a bad hack.
    call add(text, title.'*')
    call add(text, repeat('=', strlen(title)).'*')

    while 1
	let item = s:xml_get_nth(a:timeline, 'item', matchcount)
	if item == ""
	    break
	endif

	let title = s:xml_get_element(item, 'title')
	let pubdate = s:time_filter(s:xml_get_element(item, 'pubDate'))

	call add(text, s:convert_entity(title).' |'.pubdate.'|')

	let matchcount += 1
    endwhile
    call s:twitter_wintext(text)
endfunction

" Generic timeline retrieval function.
function! s:get_timeline(tline_name)
    let login = ""
    if a:tline_name == "public"
	" No authentication is needed for public timeline so just get the proxy
	" info.
	call s:get_config_proxy()
    else
	let rc = s:get_config()
	if rc < 0
	    return -1
	endif
	let login = s:login
    endif

    let url_fname = a:tline_name == "replies" ? "replies.rss" : a:tline_name."_timeline.rss"
    let output = system("curl -s ".s:proxy." ".login." http://twitter.com/statuses/".url_fname)
    if v:shell_error != 0
	echohl ErrorMsg
	echomsg "Error getting Twitter" a:tline_name "timeline. Result code: ".v:shell_error
	echomsg "Output:"
	echomsg output
	echohl None
	return
    endif

    call s:show_timeline(output)
    let s:twit_buftype = a:tline_name
endfunction

" Show direct messages.
function! s:show_dm(timeline)
    let matchcount = 1
    let text = []

    let channel = s:xml_remove_elements(a:timeline, 'item')
    let title = s:xml_get_element(channel, 'title')

    " The extra stars at the end are for the syntax highlighter to recognize
    " the title. Then the syntax highlighter hides the stars by coloring them
    " the same as the background. It is a bad hack.
    call add(text, title.'*')
    call add(text, repeat('=', strlen(title)).'*')

    while 1
	let item = s:xml_get_nth(a:timeline, 'item', matchcount)
	if item == ""
	    break
	endif

	let title = s:xml_get_element(item, 'title')
	let desc = s:xml_get_element(item, 'description')
	let pubdate = s:time_filter(s:xml_get_element(item, 'pubDate'))

	let sender = substitute(title, '^Message from \(\S\+\) to \S\+$', '\1', '')
	call add(text, sender.": ".s:convert_entity(desc).' |'.pubdate.'|')

	let matchcount += 1
    endwhile
    call s:twitter_wintext(text)
endfunction

" Get direct messages sent to user.
function! s:Direct_Messages()
    let rc = s:get_config()
    if rc < 0
	return -1
    endif

    let output = system("curl -s ".s:proxy." ".s:login." http://twitter.com/direct_messages.rss")
    if v:shell_error != 0
	echohl ErrorMsg
	echomsg "Error getting Twitter direct messages. Result code: ".v:shell_error
	echomsg "Output:"
	echomsg output
	echohl None
	return
    endif

    call s:show_dm(output)
    let s:twit_buftype = "directmessages"
endfunction

if !exists(":PublicTwitter")
    command PublicTwitter :call <SID>get_timeline("public")
endif
if !exists(":FriendsTwitter")
    command FriendsTwitter :call <SID>get_timeline("friends")
endif
if !exists(":UserTwitter")
    command UserTwitter :call <SID>get_timeline("user")
endif
if !exists(":RepliesTwitter")
    command RepliesTwitter :call <SID>get_timeline("replies")
endif
if !exists(":DMTwitter")
    command DMTwitter :call <SID>Direct_Messages()
endif

" Call Tweetburner API to shorten a URL
function! s:call_tweetburner(url)
    call s:get_config_proxy()
    let output = system('curl -s '.s:proxy.' -d link[url]="'.a:url.'" http://tweetburner.com/links')
    if v:shell_error != 0
	echohl ErrorMsg
	echomsg "Error calling Tweetburner API. Result code: ".v:shell_error
	echomsg "Output:"
	echomsg output
	echohl None
	return ""
    else
	return output
    endif
endfunction

" Invoke Tweetburner to shorten a URL and insert it at the current position in
" the current buffer.
function! s:GetTweetburner(tweetmode, url)
    let url = a:url

    " Prompt the user to enter a URL if not provided on :Tweetburner command
    " line.
    if url == ""
	call inputsave()
	let url = input("URL to shorten: ")
	call inputrestore()
    endif

    if url == ""
	echohl WarningMsg
	echo "No URL provided."
	echohl None
	return
    endif

    let shorturl = s:call_tweetburner(url)
    if shorturl != ""
	if a:tweetmode == "cmdline"
	    call s:CmdLine_Twitter(shorturl." ")
	elseif a:tweetmode == "append"
	    execute "normal a".shorturl."\<esc>"
	else
	    execute "normal i".shorturl." \<esc>"
	endif
    endif
endfunction

if !exists(":Tweetburner")
    command -nargs=? Tweetburner :call <SID>GetTweetburner("insert", <q-args>)
endif
if !exists(":ATweetburner")
    command -nargs=? ATweetburner :call <SID>GetTweetburner("append", <q-args>)
endif
if !exists(":PTweetburner")
    command -nargs=? PTweetburner :call <SID>GetTweetburner("cmdline", <q-args>)
endif

let &cpo = s:save_cpo
finish

" vim:set tw=0:
