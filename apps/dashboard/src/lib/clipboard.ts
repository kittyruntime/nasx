import { ref, readonly } from 'vue'

type ClipMode = 'copy' | 'cut'

interface ClipItem {
  paths: string[]
  mode: ClipMode
}

const _clipboard = ref<ClipItem | null>(null)

export function useClipboard() {
  function copy(paths: string[]) { _clipboard.value = { paths, mode: 'copy' } }
  function cut(paths: string[])  { _clipboard.value = { paths, mode: 'cut'  } }
  function clear()               { _clipboard.value = null }

  return { clipboard: readonly(_clipboard), copy, cut, clear }
}
