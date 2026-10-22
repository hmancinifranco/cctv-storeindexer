"""Backend package for the Video Archive prototype.

Holds the Lambda handlers and shared modules (filename parser, catalog access,
download authorization, audit). Individual modules are added by their tasks
(T3.2 parser, T3.3 indexer, T5.3 search, T5.4 download).
"""

__version__ = "0.1.0"
