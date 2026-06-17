from bs4 import BeautifulSoup, NavigableString
import difflib
import opentelemetry.trace
import prometheus_client


tracer = opentelemetry.trace.get_tracer(__name__)


BUCKETS = [0.001, 0.002, 0.003, 0.004,
           0.006, 0.008, 0.010,
           0.015, 0.020, 0.025, 0.030, 0.035, 0.04, 0.045, 0.05,
           0.06, 0.07, 0.08, 0.09, 0.10, 0.15, 0.20, 0.5, 1.0]
PROM_EXTRACT_TIME = prometheus_client.Histogram(
    'html_extract_seconds',
    "Time to extract part of an HTML document (extract.extract())",
    buckets=BUCKETS,
)
PROM_HIGHLIGHT_TIME = prometheus_client.Histogram(
    'html_highlight_seconds',
    "Time to add highlight tags to an HTML document (extract.highlight())",
    buckets=BUCKETS,
)


def split_utf8(s, pos):
    """Split a string at a given UTF-8 byte position.

    If the position falls inside of a codepoint, the string will be split after
    that codepoint.
    """
    s = s.encode('utf-8')
    while pos < len(s) and 0x80 <= s[pos] <= 0xBF:
        pos += 1
    return s[:pos].decode('utf-8'), s[pos:].decode('utf-8')


def find_pos(node, offset, after):
    """Find a position in an HTML document.
    """
    indices = []
    while True:
        if getattr(node, 'contents', None):
            indices.append(0)
            node = node.contents[0]
        else:
            if isinstance(node, NavigableString):
                nb = len(node.string.encode('utf-8'))
                if (after and nb > offset) or (not after and nb >= offset):
                    break
                else:
                    offset -= nb
            while not node.next_sibling:
                indices.pop()
                node = node.parent
            indices[-1] += 1
            node = node.next_sibling
    return node, offset, indices


def delete_left(node, indices):
    """Delete the left part of an HTML tree.
    """
    for idx in indices:
        for child in node.contents[:idx]:
            child.extract()
        node = node.contents[0]


def delete_right(node, indices):
    """Delete the right part of an HTML tree.
    """
    for idx in indices:
        del node.contents[idx + 1:]
        node = node.contents[idx]


@tracer.start_as_current_span('taguette/extract')
@PROM_EXTRACT_TIME.time()
def extract(html, start, end):
    """Extract a snippet out of an HTML document.

    Locations are computed over UTF-8 bytes, and doesn't count HTML tags.

    Extraction is aware of tags, so:

    >>> '<p><u>Hello</u> there <i>World</i></p>'[17:27]
    'here <i>Wo'
    >>> extract('<p><u>Hello</u> there <i>World</i></p>', 7, 14)
    '<p>here <i>Wo</i></p>'
    """
    soup = BeautifulSoup(html, 'html5lib')

    # Trim the right side first, because that doesn't mess our start position
    if end is not None:
        e = find_pos(soup, end, False)
        e[0].replace_with(NavigableString(split_utf8(e[0].string, e[1])[0]))
        delete_right(soup, e[2])

    # Trim the left side
    if start is not None:
        s = find_pos(soup, start, True)
        s[0].replace_with(NavigableString(split_utf8(s[0].string, s[1])[1]))
        delete_left(soup, s[2])

    # Remove everything but body
    body = soup.body
    soup.clear()
    soup.append(body)

    # Remove the body tag itself to only have the contents
    soup.body.unwrap()

    # Back to text
    return str(soup)


def document_text(html):
    """Return the document's text as UTF-8 bytes, excluding HTML tags.

    This is the exact basis over which highlight offsets are measured: the
    concatenation of every text node's UTF-8 bytes, in document order (the same
    bytes counted by ``extract()`` and ``highlight()``).
    """
    soup = BeautifulSoup(html, 'html5lib')
    return b''.join(s.encode('utf-8') for s in soup.strings)


def _common_prefix_len(a, b):
    """Length of the longest common prefix of two byte strings.

    Uses a binary search over slice comparisons (which run in C) rather than a
    byte-by-byte Python loop, so a large shared prefix stays cheap.
    """
    lo, hi = 0, min(len(a), len(b))
    while lo < hi:
        mid = (lo + hi + 1) // 2
        if a[:mid] == b[:mid]:
            lo = mid
        else:
            hi = mid - 1
    return lo


def _common_suffix_len(a, b, limit):
    """Length of the longest common suffix of two byte strings, capped at
    ``limit`` so it never overlaps an already-counted common prefix."""
    lo, hi = 0, limit
    while lo < hi:
        mid = (lo + hi + 1) // 2
        if a[len(a) - mid:] == b[len(b) - mid:]:
            lo = mid
        else:
            hi = mid - 1
    return lo


def remap_highlights(old_text, new_text, ranges):
    """Remap highlight byte ranges after a document's text was edited.

    Highlight offsets are measured over the document text as UTF-8 bytes (see
    :func:`document_text`). When that text changes, every offset past the edit
    shifts. This recomputes each ``(start, end)`` range against ``new_text``.

    :param old_text: document text (UTF-8 bytes) the ranges were measured over.
    :param new_text: edited document text (UTF-8 bytes).
    :param ranges: iterable of ``(start, end)`` byte ranges.
    :return: list with one entry per input range: the remapped ``(start, end)``,
        or ``None`` when the highlighted text was removed entirely.

    An offset in an unchanged region moves by the net length change before it.
    An offset inside an edited region snaps to that region's new bounds (a start
    snaps to the left edge, an end to the right edge), so a highlight survives
    as long as any of its text remains.

    >>> remap_highlights(b'Hello world', b'Hello brave world', [(6, 11)])
    [(12, 17)]
    >>> remap_highlights(b'12345world', b'world', [(5, 10)])
    [(0, 5)]
    >>> remap_highlights(b'Hello world', b'world', [(0, 5)])
    [None]
    """
    if old_text == new_text:
        return [(start, end) for start, end in ranges]

    # Edits are almost always localized, so the bulk of the document is an
    # unchanged prefix and suffix shared by both versions. Running difflib over
    # the whole (possibly huge) text is wasteful: trim the common prefix and
    # suffix and diff only the region that actually changed. The trimmed parts
    # are reinserted as synthetic 'equal' opcodes so the mapping below is
    # unchanged.
    old_len = len(old_text)
    new_len = len(new_text)
    prefix = _common_prefix_len(old_text, new_text)
    suffix = _common_suffix_len(
        old_text, new_text, min(old_len, new_len) - prefix,
    )
    old_mid_end = old_len - suffix
    new_mid_end = new_len - suffix

    opcodes = [
        (tag, i1 + prefix, i2 + prefix, j1 + prefix, j2 + prefix)
        for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(
            None,
            old_text[prefix:old_mid_end],
            new_text[prefix:new_mid_end],
            autojunk=False,
        ).get_opcodes()
    ]
    if prefix:
        opcodes.insert(0, ('equal', 0, prefix, 0, prefix))
    if suffix:
        opcodes.append(('equal', old_mid_end, old_len, new_mid_end, new_len))

    def map_start(offset):
        # A start offset points at the first highlighted byte: find the block
        # that *contains* it (i1 <= offset < i2).
        for tag, i1, i2, j1, j2 in opcodes:
            if i1 <= offset < i2:
                if tag == 'equal':
                    return j1 + (offset - i1)
                return j1  # edited region: snap to its left edge
        return len(new_text)  # offset at/after the end of the old text

    def map_end(offset):
        # An end offset is exclusive: find the block that *ends* at it
        # (i1 < offset <= i2).
        for tag, i1, i2, j1, j2 in opcodes:
            if i1 < offset <= i2:
                if tag == 'equal':
                    return j1 + (offset - i1)
                return j2  # edited region: snap to its right edge
        return 0  # offset at/before the start of the old text

    result = []
    for start, end in ranges:
        new_start = map_start(start)
        new_end = map_end(end)
        result.append((new_start, new_end) if new_end > new_start else None)
    return result


def byte_to_str_index(string, byte_index):
    """Converts a byte index in the UTF-8 string into a codepoint index.

    If the index falls inside of a codepoint unit, it will be rounded down.
    """
    for idx, char in enumerate(string):
        char_size = len(char.encode('utf-8'))
        if char_size > byte_index:
            return idx
        byte_index -= char_size
    return len(string)


@tracer.start_as_current_span('taguette/highlight')
@PROM_HIGHLIGHT_TIME.time()
def highlight(html, highlights, show_tags=False):
    """Highlight part of an HTML documents.

    :param highlights: Iterable of (start, end, tags) triples, which are
        computed over UTF-8 bytes and don't count HTML tags
    :param show_tags: Whether to show the tag names within brackets after each
        highlight
    """
    # Build a list of starting points and ending points
    starts = []
    ends = []
    for hl in highlights:
        starts.append((hl[0], 'start', []))
        if len(hl) == 2:
            ends.append((hl[1], 'end', []))
        else:
            ends.append((hl[1], 'end', hl[2]))
    # This relies on the fact that 'end' < 'start'
    events = sorted(ends + starts)

    events = iter(events)
    soup = BeautifulSoup(html, 'html5lib')

    pos = 0
    node = soup
    highlighting = 0
    try:
        event_pos, event_type, tags = next(events)
    except StopIteration:
        event_pos = event_type = tags = None

    while node is not None:
        if getattr(node, 'contents', None):
            # Move down
            node = node.contents[0]
            continue

        if isinstance(node, NavigableString):
            # Move through text
            nb = len(node.string.encode('utf-8'))
            while event_pos is not None:
                if event_pos == pos and event_type == 'start':
                    # Start highlighting at beginning of text node
                    highlighting += 1
                    try:
                        event_pos, event_type, tags = next(events)
                    except StopIteration:
                        event_pos = None
                elif pos + nb > event_pos:
                    # Next event falls inside of this text node
                    if event_type == 'start' and highlighting:
                        # Keep highlighting (can't highlight *more*)
                        highlighting += 1
                    elif (
                        event_type == 'end'
                        and not show_tags
                        and highlighting > 1
                    ):
                        # Keep highlighting (no need to put labels)
                        highlighting -= 1
                    else:  # 'end' and (show_tags or highlighting becomes 0)
                        # Split it
                        char_idx = byte_to_str_index(
                            node.string,
                            event_pos - pos,
                        )
                        left = node.string[:char_idx]
                        right = node.string[char_idx:]

                        # Left part
                        newnode = NavigableString(left)
                        if highlighting:
                            # Optionally highlight left part
                            span = soup.new_tag(
                                'span',
                                attrs={'class': 'highlight'},
                            )
                            span.append(newnode)
                            newnode = span
                        node.replace_with(newnode)
                        node = newnode

                        if event_type == 'start':
                            highlighting += 1
                        else:
                            highlighting -= 1
                            if show_tags:
                                # Add tag labels
                                comment = soup.new_tag(
                                    'span',
                                    attrs={'class': 'taglist'},
                                )
                                comment.string = ' [%s]' % ', '.join(tags)
                                node.insert_after(comment)
                                node = comment

                        # Right part
                        newnode = NavigableString(right)
                        node.insert_after(newnode)
                        node = newnode
                        nb -= event_pos - pos
                        pos = event_pos
                        # Next loop will highlight right part if needed

                    try:
                        event_pos, event_type, tags = next(events)
                    except StopIteration:
                        event_pos = None
                elif highlighting:  # and pos + nb <= event_pos:
                    # Highlight whole text node
                    newnode = soup.new_tag(
                        'span',
                        attrs={'class': 'highlight'},
                    )
                    node.replace_with(newnode)
                    newnode.append(node)
                    node = newnode
                    if pos + nb == event_pos and event_type == 'end':
                        if show_tags:
                            comment = soup.new_tag(
                                'span',
                                attrs={'class': 'taglist'},
                            )
                            comment.string = ' [%s]' % ', '.join(tags)
                            newnode.insert_after(comment)
                            node = comment
                        highlighting -= 1
                        try:
                            event_pos, event_type, tags = next(events)
                        except StopIteration:
                            event_pos = None
                    break
                else:  # not highlighting and pos + nb <= event_pos
                    # Skip whole text node
                    break

            pos += nb

        # Move up until there's a sibling
        while not node.next_sibling and node.parent:
            node = node.parent
        if not node.parent:
            break
        # Move to next node
        node = node.next_sibling

    # Remove everything but body
    body = soup.body
    soup.clear()
    soup.append(body)

    # Remove the body tag itself to only have the contents
    soup.body.unwrap()

    # Back to text
    return str(soup)
