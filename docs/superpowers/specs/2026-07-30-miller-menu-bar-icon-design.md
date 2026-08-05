# Miller Menu-Bar Icon Design

## Decision

Replace Miller's variable-width text status item with a square monochrome
template icon derived from the complete Millrace silhouette.

The approved treatment is the intact Millrace mark at its exact source weight,
with no optical dilation. The asset must not crop, simplify, recolor, glow, or
alter the silhouette's geometry or scaled alpha.

## Presentation

- Display the icon at 18 points inside a square status-item slot.
- Provide high-resolution source pixels for Retina rendering.
- Mark the image as a macOS template so the system supplies light, dark,
  highlighted, and disabled-state tinting.
- Remove the visible `Miller` title from the status item.
- Preserve `Miller` as the tooltip and `Miller status` as the accessibility
  description.

Shortcut-registration failure must not deform or replace the Millrace
silhouette. Settings, menu text, tooltip, and accessibility state may report
the failure. The menu-bar icon itself remains stable.

## Ownership and Provenance

Miller owns the packaged derivative. Its provenance record identifies the
canonical Millrace source asset and describes the bounded monochrome and
aspect-fit transformation with no optical dilation.

The asset is a presentation resource. It has no effect on Miller Core,
conversation state, gateway behavior, persistence, or provider operation.

## Verification

Automated checks must prove:

- the packaged resource exists and loads;
- the image is configured as a template;
- the status item uses an image without a visible text title;
- tooltip and accessibility descriptions remain present; and
- existing Swift and packaging checks continue to pass.

Human Gate H1 must additionally confirm that the icon:

- is visible and recognizable at actual menu-bar size;
- remains legible in the current menu-bar appearance;
- consumes substantially less width than the former text label; and
- does not impair menu access, global activation, or status presentation.

macOS may hide any third-party status item when the menu bar has no available
space. Miller cannot override that system behavior; global activation remains
the fallback.
