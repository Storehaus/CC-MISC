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

## Internal Information
The queue system is generic, and can support calling any method on the `abstractInvLib` object. Use the `queueAction` function to queue a given event, it will return a randomly generated ID that corrosponds to the transfer.

Immediately after a transfer is finished (in its coroutine) the `"inventoryFinished", id, ...` event is queued.
