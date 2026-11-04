// The one place a secret text field's masking is defined.
// SPDX-License-Identifier: MIT
//
// A secret field needs both halves at once: the visual transformation that draws
// bullets instead of the draft, and the `password()` semantics that tells
// accessibility the value must not be announced. Keeping them together means a
// page cannot pick up one half and silently leak the plaintext through the other.
// Call sites still own their keyboard type, labels, placeholders and test tags.
package com.phonedsh.ui.surface

import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.password
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation

/** Draws a secret's draft as bullets; never the text the user typed. */
internal val SecretVisualTransformation: VisualTransformation = PasswordVisualTransformation()

/** Marks a text field's semantics node as a password, hiding its value from a11y. */
internal fun Modifier.secretInputSemantics(): Modifier = semantics { password() }
