local Capabilities = {
    SEARCH = "search",
    BOOK_INFO = "book_info",
    CATALOG = "catalog",
    CONTENT = "content",
}

Capabilities.CORE = {
    Capabilities.SEARCH,
    Capabilities.BOOK_INFO,
    Capabilities.CATALOG,
    Capabilities.CONTENT,
}

return Capabilities
