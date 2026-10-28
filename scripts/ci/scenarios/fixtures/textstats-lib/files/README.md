# textstats 1.0

Count words and rank the most frequent ones.

```python
from textstats import count_words, top_words

count_words("apple banana apple")      # {"apple": 2, "banana": 1}
top_words("pear pear apple", 2)        # [("pear", 2), ("apple", 1)]
```

Ties are ordered alphabetically. Version 1.0 does not filter stop words.
