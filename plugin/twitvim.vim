" ==============================================================
" TwitVim - Post to Twitter from Vim
" Based on Twitter Vim script by Travis Jeffery <eatsleepgolf@gmail.com>
"
" Version: 0.2.16
" License: Vim license. See :help license
" Language: Vim script
" Maintainer: Po Shan Cheah <morton@mortonfox.com>
" Created: March 28, 2008
" Last updated: May 16, 2008
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
    let s:proxy = exists('g:twitvim_proxy') ? '-x "'.g:twitvim_proxy.'"': ""
    " If twitvim_proxy_login exists, use that as the proxy login.
    " Format is proxyuser:proxypassword
    " If twitvim_proxy_login_b64 exists, use that instead. This is the proxy
    " user:password in base64 encoding.
    if exists('g:twitvim_proxy_login_b64')
	let s:proxy .= ' -H "Proxy-Authorization: Basic '.g:twitvim_proxy_login_b64.'"'
    else
	let s:proxy .= exists('g:twitvim_proxy_login') ? ' -U "'.g:twitvim_proxy_login.'"' : ''
    endif
endfunction

" Get user-config variables twitvim_proxy and twitvim_login.
function! s:get_config()
    call s:get_config_proxy()

    " Get Twitter login info from twitvim_login in .vimrc or _vimrc.
    " Format is username:password
    " If twitvim_login_b64 exists, use that instead. This is the user:password
    " in base64 encoding.
    if exists('g:twitvim_login_b64')
	let s:login = '-H "Authorization: Basic '.g:twitvim_login_b64.'"'	
    elseif exists('g:twitvim_login') && g:twitvim_login != ''
	let s:login = '-u "'.g:twitvim_login.'"'
    else
	" Beep and error-highlight 
	execute "normal \<Esc>"
	redraw
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

" === End of XML helper functions ===

" === Perl time string parser ===

if has('perl') && !g:twitvim_disable_simple_time
    function s:def_perl_time_funcs()
	perl <<EOF
eval {
    require Time::Local; Time::Local->import;
    require POSIX; POSIX->import(qw(strftime));
};
if ($@) {
    # Play it safe and disable this feature if modules fail to load.
    VIM::DoCommand('let g:twitvim_disable_simple_time = 1');
}

# Convert abbreviated month name to month number.
sub twitvim_conv_month {
    my $monthstr = shift;
    my @months = qw(jan feb mar apr may jun jul aug sep oct nov dec);
    for my $mon (0..11) {
	$months[$mon] eq lc($monthstr) and return $mon;
    }
    undef;
}

# Parse time string in Twitter RSS or Summize Atom format.
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
    # This timestamp format is used by Summize.
    elsif ($timestr =~ /^(\d+)-(\d+)-(\d+)T(\d+):(\d+):(\d+)Z$/) {
	return timegm($6, $5, $4, $3, $2 - 1, $1);
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

" === End of Perl time string parser ===

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
	    normal 1G
	    wincmd p
	endif
    endif
endfunction

" URL-encode a string.
function! s:url_encode(str)
    return substitute(a:str, '[^a-zA-Z_-]', '\=printf("%%%02X", char2nr(submatch(0)))', 'g')
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
	redraw
	echohl WarningMsg
	echo "Your tweet has" strlen(mesg) - s:char_limit
	    \ "too many characters. It was not sent."
	echohl None
    elseif strlen(mesg) < 1
	redraw
	echohl WarningMsg
	echo "Your tweet was empty. It was not sent."
	echohl None
    else
	redraw
	echo "Sending update to Twitter..."
	let output = system("curl -s ".s:proxy." ".s:login.' -d status="'.s:url_encode(mesg).'" '.s:twupdate)
	if v:shell_error != 0
	    redraw
	    echohl ErrorMsg
	    echomsg "Error posting your tweet. Result code: ".v:shell_error
	    echomsg "Output:"
	    echomsg output
	    echohl None
	else
	    call s:add_update(output)
	    redraw
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

" Extract the user name from a line in the timeline.
function! s:get_user_name(line)
    let matchres = matchlist(a:line, '^\(\w\+\):')
    return matchres != [] ? matchres[1] : ""
endfunction

" This is for a local mapping in the timeline. Start an @-reply on the command
" line to the author of the tweet on the current line.
function! s:Quick_Reply()
    let username = s:get_user_name(getline('.'))
    if username != ""
	call s:CmdLine_Twitter('@'.username.' ')
    endif
endfunction

" This is for a local mapping in the timeline. Start a direct message on the
" command line to the author of the tweet on the current line.
function! s:Quick_DM()
    let username = s:get_user_name(getline('.'))
    if username != ""
	call s:CmdLine_Twitter('d '.username.' ')
    endif
endfunction


" Prompt user for tweet.
if !exists(":PosttoTwitter")
    command PosttoTwitter :call <SID>CmdLine_Twitter('')
endif

nnoremenu Plugin.TwitVim.Post\ from\ cmdline :call <SID>CmdLine_Twitter('')<cr>

" Post current line to Twitter.
if !exists(":CPosttoTwitter")
    command CPosttoTwitter :call <SID>post_twitter(getline('.'))
endif

nnoremenu Plugin.TwitVim.Post\ current\ line :call <SID>post_twitter(getline('.'))<cr>

" Post entire buffer to Twitter.
if !exists(":BPosttoTwitter")
    command BPosttoTwitter :call <SID>post_twitter(join(getline(1, "$")))
endif

" Post visual selection to Twitter.
noremap <SID>Visual y:call <SID>post_twitter(@")<cr>
noremap <unique> <script> <Plug>TwitvimVisual <SID>Visual
if !hasmapto('<Plug>TwitvimVisual')
    vmap <unique> <A-t> <Plug>TwitvimVisual

    " Allow Ctrl-T as an alternative to Alt-T.
    " Alt-T pulls down the Tools menu if the menu bar is enabled.
    vmap <unique> <C-t> <Plug>TwitvimVisual
endif

vmenu Plugin.TwitVim.Post\ selection <Plug>TwitvimVisual

" Launch web browser with the given URL.
function! s:launch_browser(url)
    if !exists('g:twitvim_browser_cmd') || g:twitvim_browser_cmd == ''
	" Beep and error-highlight 
	execute "normal \<Esc>"
	redraw
	echohl ErrorMsg
	echomsg 'Browser cmd not set.'
	    \ 'Please add to .vimrc: let twitvim_browser_cmd="browsercmd"'
	echohl None
	return -1
    endif

    let startcmd = has("win32") || has("win64") ? "!start " : "! "
    let endcmd = has("unix") ? "&" : ""

    " Escape characters that have special meaning in the :! command.
    let url = substitute(a:url, '!\|#\|%', '\\&', 'g')

    redraw
    echo "Launching web browser..."
    silent execute startcmd g:twitvim_browser_cmd url endcmd
    redraw
    echo "Web browser launched."
endfunction

" Launch web browser with the URL at the cursor position. If possible, this
" function will try to recognize a URL within the current word. Otherwise,
" it'll just use the whole word.
" If the cWORD happens to be @user or user:, show that user's timeline.
function! s:launch_url_cword()
    let s = expand("<cWORD>")

    let matchres = matchlist(s, '^@\(\w\+\)')
    if matchres != []
	call s:get_timeline("user", matchres[1])
	return
    endif

    let matchres = matchlist(s, '^\(\w\+\):$')
    if matchres != []
	call s:get_timeline("user", matchres[1])
	return
    endif

    let s = substitute(s, '.*\<\(\(http\|https\|ftp\)://\S\+\)', '\1', "")
    call s:launch_browser(s)
endfunction

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
	nnoremap <buffer> <silent> <Leader>r :call <SID>Quick_Reply()<cr>

	" Quick DM feature for direct messaging from the timeline.
	nnoremap <buffer> <silent> <A-d> :call <SID>Quick_DM()<cr>
	nnoremap <buffer> <silent> <Leader>d :call <SID>Quick_DM()<cr>

	" Launch browser with URL in visual selection or at cursor position.
	nnoremap <buffer> <silent> <A-g> :call <SID>launch_url_cword()<cr>
	nnoremap <buffer> <silent> <Leader>g :call <SID>launch_url_cword()<cr>
	vnoremap <buffer> <silent> <A-g> y:call <SID>launch_browser(@")<cr>
	vnoremap <buffer> <silent> <Leader>g y:call <SID>launch_browser(@")<cr>

	" Beautify the Twitter window with syntax highlighting.
	if has("syntax") && exists("g:syntax_on") && !has("syntax_items")

	    " Twitter user name: from start of line to first colon.
	    syntax match twitterUser /^.\{-1,}:/

	    " Use the bars to recognize the time but hide the bars.
	    syntax match twitterTime /|[^|]\+|$/ contains=twitterTimeBar
	    syntax match twitterTimeBar /|/ contained

	    " Highlight links in tweets.
	    syntax match twitterLink "\<http://\S\+"
	    syntax match twitterLink "\<https://\S\+"
	    syntax match twitterLink "\<ftp://\S\+"

	    " An @-reply must be preceded by whitespace and ends at a non-word
	    " character.
	    syntax match twitterReply "\S\@<!@\w\+"

	    " Use the extra star at the end to recognize the title but hide the
	    " star.
	    syntax match twitterTitle /^.\+\*$/ contains=twitterTitleStar
	    syntax match twitterTitleStar /\*$/ contained

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
    " Delete to the blackhole register "_ so that we don't affect registers.
    silent %delete _
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
function! s:get_timeline(tline_name, username)
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

    " Twitter API allows you to specify a username for user timeline and
    " friends timeline to retrieve another user's timeline.
    let user = a:username == '' ? '' : '/'.a:username

    let url_fname = a:tline_name == "replies" ? "replies.rss" : a:tline_name."_timeline".user.".rss"

    redraw
    echo "Sending" a:tline_name "timeline request to Twitter..."
    let output = system("curl -s ".s:proxy." ".login." http://twitter.com/statuses/".url_fname)
    if v:shell_error != 0
	redraw
	echohl ErrorMsg
	echomsg "Error getting Twitter" a:tline_name "timeline. Result code: ".v:shell_error
	echomsg "Output:"
	echomsg output
	echohl None
	return
    endif

    call s:show_timeline(output)
    let s:twit_buftype = a:tline_name
    redraw

    let foruser = a:username == '' ? '' : ' for user '.a:username

    " Uppercase the first letter in the timeline name.
    echo substitute(a:tline_name, '^.', '\u&', '') "timeline updated".foruser."."
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

    redraw
    echo "Sending direct message timeline request to Twitter..."
    let output = system("curl -s ".s:proxy." ".s:login." http://twitter.com/direct_messages.rss")
    if v:shell_error != 0
	redraw
	echohl ErrorMsg
	echomsg "Error getting Twitter direct messages. Result code: ".v:shell_error
	echomsg "Output:"
	echomsg output
	echohl None
	return
    endif

    call s:show_dm(output)
    let s:twit_buftype = "directmessages"
    redraw
    echo "Direct message timeline updated."
endfunction

if !exists(":PublicTwitter")
    command PublicTwitter :call <SID>get_timeline("public", '')
endif
if !exists(":FriendsTwitter")
    command -nargs=? FriendsTwitter :call <SID>get_timeline("friends", <q-args>)
endif
if !exists(":UserTwitter")
    command -nargs=? UserTwitter :call <SID>get_timeline("user", <q-args>)
endif
if !exists(":RepliesTwitter")
    command RepliesTwitter :call <SID>get_timeline("replies", '')
endif
if !exists(":DMTwitter")
    command DMTwitter :call <SID>Direct_Messages()
endif

nnoremenu Plugin.TwitVim.-Sep1- :
nnoremenu Plugin.TwitVim.&Friends\ Timeline :call <SID>get_timeline("friends", '')<cr>
nnoremenu Plugin.TwitVim.&User\ Timeline :call <SID>get_timeline("user", '')<cr>
nnoremenu Plugin.TwitVim.&Replies\ Timeline :call <SID>get_timeline("replies", '')<cr>
nnoremenu Plugin.TwitVim.&Direct\ Messages :call <SID>Direct_Messages()<cr>
nnoremenu Plugin.TwitVim.&Public\ Timeline :call <SID>get_timeline("public", '')<cr>

" Call Tweetburner API to shorten a URL.
function! s:call_tweetburner(url)
    call s:get_config_proxy()
    redraw
    echo "Sending request to Tweetburner..."
    let output = system('curl -s '.s:proxy.' -d link[url]="'.s:url_encode(a:url).'" http://tweetburner.com/links')
    if v:shell_error != 0
	redraw
	echohl ErrorMsg
	echomsg "Error calling Tweetburner API. Result code: ".v:shell_error
	echomsg "Output:"
	echomsg output
	echohl None
	return ""
    else
	redraw
	echo "Received response from Tweetburner."
	return output
    endif
endfunction

" Call SnipURL API to shorten a URL.
function! s:call_snipurl(url)
    call s:get_config_proxy()
    redraw
    echo "Sending request to SnipURL..."
    let output = system('curl -s '.s:proxy.' "http://snipr.com/site/snip?r=simple&link='.s:url_encode(a:url).'"')
    if v:shell_error != 0
	redraw
	echohl ErrorMsg
	echomsg "Error calling SnipURL API. Result code: ".v:shell_error
	echomsg "Output:"
	echomsg output
	echohl None
	return ""
    else
	redraw
	echo "Received response from SnipURL."
	" Get rid of extraneous newline at the beginning of SnipURL's output.
	return substitute(output, '^\n', '', '')
    endif
endfunction

" Call Metamark API to shorten a URL.
function! s:call_metamark(url)
    call s:get_config_proxy()
    redraw
    echo "Sending request to Metamark..."
    let output = system('curl -s '.s:proxy.' -d long_url="'.s:url_encode(a:url).'" http://metamark.net/api/rest/simple')
    if v:shell_error != 0
	redraw
	echohl ErrorMsg
	echomsg "Error calling Metamark API. Result code: ".v:shell_error
	echomsg "Output:"
	echomsg output
	echohl None
	return ""
    else
	redraw
	echo "Received response from Metamark."
	return output
    endif
endfunction

" Call TinyURL API to shorten a URL.
function! s:call_tinyurl(url)
    call s:get_config_proxy()
    redraw
    echo "Sending request to TinyURL..."
    let output = system('curl -s '.s:proxy.' "http://tinyurl.com/api-create.php?url='.a:url.'"')
    if v:shell_error != 0
	redraw
	echohl ErrorMsg
	echomsg "Error calling TinyURL API. Result code: ".v:shell_error
	echomsg "Output:"
	echomsg output
	echohl None
	return ""
    else
	redraw
	echo "Received response from TinyURL."
	return output
    endif
endfunction

" Call urlTea API to shorten a URL.
function! s:call_urltea(url)
    call s:get_config_proxy()
    redraw
    echo "Sending request to urlTea..."
    let output = system('curl -s '.s:proxy.' "http://urltea.com/api/text/?url='.s:url_encode(a:url).'"')
    if v:shell_error != 0
	redraw
	echohl ErrorMsg
	echomsg "Error calling urlTea API. Result code: ".v:shell_error
	echomsg "Output:"
	echomsg output
	echohl None
	return ""
    else
	redraw
	echo "Received response from urlTea."
	return output
    endif
endfunction

" Invoke URL shortening service to shorten a URL and insert it at the current
" position in the current buffer.
function! s:GetShortURL(tweetmode, url, shortfn)
    let url = a:url

    " Prompt the user to enter a URL if not provided on :Tweetburner command
    " line.
    if url == ""
	call inputsave()
	let url = input("URL to shorten: ")
	call inputrestore()
    endif

    if url == ""
	redraw
	echohl WarningMsg
	echo "No URL provided."
	echohl None
	return
    endif

    let shorturl = call(function("s:".a:shortfn), [url])
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
    command -nargs=? Tweetburner :call <SID>GetShortURL("insert", <q-args>, "call_tweetburner")
endif
if !exists(":ATweetburner")
    command -nargs=? ATweetburner :call <SID>GetShortURL("append", <q-args>, "call_tweetburner")
endif
if !exists(":PTweetburner")
    command -nargs=? PTweetburner :call <SID>GetShortURL("cmdline", <q-args>, "call_tweetburner")
endif

if !exists(":Snipurl")
    command -nargs=? Snipurl :call <SID>GetShortURL("insert", <q-args>, "call_snipurl")
endif
if !exists(":ASnipurl")
    command -nargs=? ASnipurl :call <SID>GetShortURL("append", <q-args>, "call_snipurl")
endif
if !exists(":PSnipurl")
    command -nargs=? PSnipurl :call <SID>GetShortURL("cmdline", <q-args>, "call_snipurl")
endif

if !exists(":Metamark")
    command -nargs=? Metamark :call <SID>GetShortURL("insert", <q-args>, "call_metamark")
endif
if !exists(":AMetamark")
    command -nargs=? AMetamark :call <SID>GetShortURL("append", <q-args>, "call_metamark")
endif
if !exists(":PMetamark")
    command -nargs=? PMetamark :call <SID>GetShortURL("cmdline", <q-args>, "call_metamark")
endif

if !exists(":TinyURL")
    command -nargs=? TinyURL :call <SID>GetShortURL("insert", <q-args>, "call_tinyurl")
endif
if !exists(":ATinyURL")
    command -nargs=? ATinyURL :call <SID>GetShortURL("append", <q-args>, "call_tinyurl")
endif
if !exists(":PTinyURL")
    command -nargs=? PTinyURL :call <SID>GetShortURL("cmdline", <q-args>, "call_tinyurl")
endif

if !exists(":UrlTea")
    command -nargs=? UrlTea :call <SID>GetShortURL("insert", <q-args>, "call_urltea")
endif
if !exists(":AUrlTea")
    command -nargs=? AUrlTea :call <SID>GetShortURL("append", <q-args>, "call_urltea")
endif
if !exists(":PUrlTea")
    command -nargs=? PUrlTea :call <SID>GetShortURL("cmdline", <q-args>, "call_urltea")
endif

" Parse and format search results from Summize API.
function! s:show_summize(searchres)
    let text = []
    let matchcount = 1

    let channel = s:xml_remove_elements(a:searchres, 'entry')
    let title = s:xml_get_element(channel, 'title')

    " The extra stars at the end are for the syntax highlighter to recognize
    " the title. Then the syntax highlighter hides the stars by coloring them
    " the same as the background. It is a bad hack.
    call add(text, title.'*')
    call add(text, repeat('=', strlen(title)).'*')

    while 1
	let item = s:xml_get_nth(a:searchres, 'entry', matchcount)
	if item == ""
	    break
	endif

	let title = s:xml_get_element(item, 'title')
	let pubdate = s:time_filter(s:xml_get_element(item, 'updated'))
	let sender = substitute(s:xml_get_element(item, 'uri'), 'http://twitter.com/', '', '')

	call add(text, sender.": ".s:convert_entity(title).' |'.pubdate.'|')

	let matchcount += 1
    endwhile
    call s:twitter_wintext(text)
endfunction

" Query Summize API and retrieve results
function! s:get_summize(query)
    call s:get_config_proxy()

    redraw
    echo "Sending search request to Summize..."

    let output = system("curl -s ".s:proxy.' "http://summize.com/search.atom?rpp=25&q='.s:url_encode(a:query).'"')
    if v:shell_error != 0
	redraw
	echohl ErrorMsg
	echomsg "Error getting search results from Summize. Result code: ".v:shell_error
	echomsg "Output:"
	echomsg output
	echohl None
	return
    endif

    call s:show_summize(output)
    let s:twit_buftype = "summize"
    redraw
    echo "Received search results from Summize."
endfunction

" Prompt user for Summize query string if not entered on command line.
function! s:Summize(query)
    let query = a:query

    " Prompt the user to enter a query if not provided on :Summize command
    " line.
    if query == ""
	call inputsave()
	let query = input("Search Summize: ")
	call inputrestore()
    endif

    if query == ""
	redraw
	echohl WarningMsg
	echo "No query provided for Summize search."
	echohl None
	return
    endif

    call s:get_summize(query)
endfunction

if !exists(":Summize")
    command -nargs=? Summize :call <SID>Summize(<q-args>)
endif

let &cpo = s:save_cpo
finish

" vim:set tw=0:
