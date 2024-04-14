---
title: '`inventory.lua`'
parent: Modules
---
# `inventory.lua`
This module is the main backbone of the storage system. It uses `abstractInvLib` to wrap any number of inventories together, to act as the main storage capacity of the system.

## Interface Information
All methods from `abstractInvLib` are available through `loaded.inventory.interface` once it's initialized. 

All transfers performed on the inventory are added to a queue, which is periodically flushed following the configuration settings.

Each time the queue is flushed, an `"inventoryUpdate"` event is queued. The second value of this event is the `list` of the inventory state.
