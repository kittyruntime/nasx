import { ref, watchEffect } from 'vue'

export type Theme = 'auto' | 'light' | 'dark'

const STORAGE_KEY = 'nasx-theme'

function readStored(): Theme {
  const v = localStorage.getItem(STORAGE_KEY)
  return v === 'light' || v === 'dark' ? v : 'auto'
}

const theme = ref<Theme>(readStored())

watchEffect(() => {
  const html = document.documentElement
  if (theme.value === 'auto') {
    html.removeAttribute('data-theme')
    localStorage.removeItem(STORAGE_KEY)
  } else {
    html.setAttribute('data-theme', theme.value)
    localStorage.setItem(STORAGE_KEY, theme.value)
  }
})

export function useTheme() {
  function cycle() {
    if (theme.value === 'auto')  theme.value = 'light'
    else if (theme.value === 'light') theme.value = 'dark'
    else theme.value = 'auto'
  }
  return { theme, cycle }
}
