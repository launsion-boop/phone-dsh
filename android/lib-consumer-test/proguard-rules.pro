# SPDX-License-Identifier: MIT
#
# The consumer's own R8 rules. Deliberately empty of product rules: this module
# exists to answer whether the *library's* rules are enough, so it adds nothing
# of its own.
#
# It is not empty of *consumer* rules in general: an app that actually embeds the
# SDK must add whatever its own platform integrations need (a WebView JS bridge,
# a serialized model, ...). Nothing here should ever be needed just to keep a
# public SDK class alive — if it were, that would be the library's gap, and it
# belongs in :lib's consumer-rules.pro instead.
