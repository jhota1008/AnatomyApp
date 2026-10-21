<script setup lang="ts">
import { computed, nextTick, onMounted, onUnmounted, ref, watch } from 'vue'
import type { User } from '@supabase/supabase-js'
import { isSupabaseConfigured, supabase } from './supabase'

type Structure = {
  id: string
  name: string
  x: number
  y: number
  labelX?: number | null
  labelY?: number | null
  targetType?: 'point' | 'circle'
  radius?: number | null
}

type Diagram = {
  id: string
  ownerId: string
  title: string
  image: string
  imagePath: string
  folderId: string | null
  folderName: string
  tags: string[]
  visibility: 'private' | 'public'
  structures: Structure[]
  updatedAt: number
}

type Folder = { id: string; name: string }

type LocalDiagram = Omit<Diagram, 'imagePath' | 'ownerId' | 'folderId' | 'folderName' | 'tags' | 'visibility'> & {
  imagePath?: string
  folderName?: string
  tags?: string[]
  visibility?: 'private' | 'public'
}

const storageKey = 'anatomy-study-diagrams'
const databaseName = 'fieldnotes-anatomy'
const storageBucket = 'anatomy-diagrams'
const diagrams = ref<Diagram[]>([])
const folders = ref<Folder[]>([])
const legacyDiagrams = ref<LocalDiagram[]>([])
const selectedId = ref('')
const libraryView = ref<'mine' | 'public'>('mine')
const folderFilter = ref('')
const newFolderOpen = ref(false)
const newFolderName = ref('')
const newFolderNameInput = ref<HTMLInputElement | null>(null)
const folderBusy = ref(false)
const tagFilter = ref('')
const tagDraft = ref('')
const shareMessage = ref('')
const mode = ref<'edit' | 'study'>('edit')
const placing = ref(false)
const pendingPoint = ref<{
  x: number
  y: number
  labelX: number
  labelY: number
  targetType: 'point' | 'circle'
  radius: number | null
} | null>(null)
const labelTargetType = ref<'point' | 'circle'>('point')
const circleStart = ref<{ x: number; y: number } | null>(null)
const circleDraft = ref<{ x: number; y: number; radius: number } | null>(null)
const structureName = ref('')
const answers = ref<Record<string, string>>({})
const checked = ref(false)
const replacingImage = ref(false)
const imageInput = ref<HTMLInputElement | null>(null)
const structureNameInput = ref<HTMLInputElement | null>(null)
const diagramStage = ref<HTMLElement | null>(null)
const draggingLabelId = ref<string | null>(null)
const user = ref<User | null>(null)
const cloudReady = ref(false)
const authMode = ref<'signin' | 'signup'>('signin')
const authEmail = ref('')
const authPassword = ref('')
const authBusy = ref(false)
const uploadBusy = ref(false)
const importBusy = ref(false)
const authMessage = ref('')
const appError = ref('')
const saveState = ref<'saved' | 'saving' | 'error'>('saved')
let saveTimer: number | undefined
let authSubscription: { unsubscribe: () => void } | undefined
const pendingDiagramIds = new Set<string>()

const activeDiagram = computed(() => diagrams.value.find((diagram) => diagram.id === selectedId.value))
const canEditActive = computed(() => Boolean(activeDiagram.value && user.value && activeDiagram.value.ownerId === user.value.id))
const libraryDiagrams = computed(() => diagrams.value.filter((diagram) =>
    libraryView.value === 'mine' ? diagram.ownerId === user.value?.id : diagram.visibility === 'public',
  ))
const visibleDiagrams = computed(() => libraryDiagrams.value.filter((diagram) =>
  (!folderFilter.value || diagram.folderId === folderFilter.value)
  && (!tagFilter.value || diagram.tags.includes(tagFilter.value)),
))
const availableFolders = computed(() => [...folders.value].sort((first, second) => first.name.localeCompare(second.name)))
const availableTags = computed(() => [...new Set(libraryDiagrams.value.flatMap((diagram) => diagram.tags))].sort())
const correctCount = computed(() => {
  if (!activeDiagram.value) return 0
  return activeDiagram.value.structures.filter((structure) => isCorrect(structure)).length
})

watch(
  diagrams,
  () => {
    if (!cloudReady.value || !user.value) return
    if (selectedId.value) pendingDiagramIds.add(selectedId.value)
    saveState.value = 'saving'
    window.clearTimeout(saveTimer)
    saveTimer = window.setTimeout(() => {
      const changedIds = [...pendingDiagramIds]
      pendingDiagramIds.clear()
      for (const id of changedIds) {
        const diagram = diagrams.value.find((item) => item.id === id)
        if (diagram) void persistDiagram(diagram)
      }
    }, 450)
  },
  { deep: true },
)

onMounted(async () => {
  if (!supabase) return
  const { data, error } = await supabase.auth.getSession()
  if (error) appError.value = error.message
  if (data.session?.user) {
    user.value = data.session.user
    await loadCloudDiagrams()
  }
  const { data: authData } = supabase.auth.onAuthStateChange((_event, session) => {
    window.setTimeout(() => {
      user.value = session?.user ?? null
      if (session?.user) void loadCloudDiagrams()
      else {
        diagrams.value = []
        folders.value = []
        selectedId.value = ''
        legacyDiagrams.value = []
        cloudReady.value = false
      }
    }, 0)
  })
  authSubscription = authData.subscription
  window.addEventListener('focus', refreshImageUrls)
})

onUnmounted(() => {
  authSubscription?.unsubscribe()
  window.removeEventListener('focus', refreshImageUrls)
  window.clearTimeout(saveTimer)
})

function openDatabase(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(databaseName, 1)
    request.onupgradeneeded = () => request.result.createObjectStore('library')
    request.onsuccess = () => resolve(request.result)
    request.onerror = () => reject(request.error)
  })
}

async function readLocalDiagrams(): Promise<LocalDiagram[]> {
  try {
    const database = await openDatabase()
    return await new Promise((resolve, reject) => {
      const request = database.transaction('library', 'readonly').objectStore('library').get('diagrams')
      request.onsuccess = () => {
        database.close()
        resolve((request.result as LocalDiagram[] | undefined) ?? [])
      }
      request.onerror = () => {
        database.close()
        reject(request.error)
      }
    })
  } catch {
    try {
      const stored = localStorage.getItem(storageKey)
      return stored ? (JSON.parse(stored) as LocalDiagram[]) : []
    } catch {
      return []
    }
  }
}

async function writeLocalDiagrams(value: LocalDiagram[]) {
  try {
    const database = await openDatabase()
    await new Promise<void>((resolve, reject) => {
      const transaction = database.transaction('library', 'readwrite')
      transaction.objectStore('library').put(value, 'diagrams')
      transaction.oncomplete = () => resolve()
      transaction.onerror = () => reject(transaction.error)
      transaction.onabort = () => reject(transaction.error)
    })
    database.close()
    if (!value.length) localStorage.removeItem(storageKey)
  } catch {
    if (value.length) localStorage.setItem(storageKey, JSON.stringify(value))
    else localStorage.removeItem(storageKey)
  }
}

async function loadCloudDiagrams() {
  if (!supabase || !user.value) return
  cloudReady.value = false
  appError.value = ''
  try {
    const { data: folderRows, error: folderError } = await supabase
      .from('folders')
      .select('id, name')
      .eq('user_id', user.value.id)
      .order('name')
    if (folderError) throw folderError
    folders.value = folderRows ?? []

    const { data, error } = await supabase
      .from('diagrams')
      .select('id, user_id, title, image_path, folder_id, updated_at, tags, visibility, structures(id, name, x, y, label_x, label_y, target_type, radius, position)')
      .or(`user_id.eq.${user.value.id},visibility.eq.public`)
      .order('updated_at', { ascending: false })
    if (error) throw error

    const loaded: Diagram[] = []
    for (const row of data ?? []) {
      const { data: signedImage, error: imageError } = await supabase.storage
        .from(storageBucket)
        .createSignedUrl(row.image_path, 60 * 60 * 24)
      if (imageError) throw imageError
      loaded.push({
        id: row.id,
        ownerId: row.user_id,
        title: row.title,
        image: signedImage.signedUrl,
        imagePath: row.image_path,
        folderId: row.folder_id,
        folderName: folders.value.find((folder) => folder.id === row.folder_id)?.name ?? '',
        tags: row.tags ?? [],
        visibility: row.visibility ?? 'private',
        updatedAt: new Date(row.updated_at).getTime(),
        structures: [...(row.structures ?? [])]
          .sort((first, second) => first.position - second.position)
          .map(({ id, name, x, y, label_x, label_y, target_type, radius }) => ({
            id,
            name,
            x,
            y,
            labelX: label_x,
            labelY: label_y,
            targetType: target_type ?? 'point',
            radius,
          })),
      })
    }
    diagrams.value = loaded
    const requestedDiagramId = new URLSearchParams(window.location.search).get('diagram')
    const requestedDiagram = loaded.find((diagram) => diagram.id === requestedDiagramId)
    selectedId.value = requestedDiagram?.id ?? loaded[0]?.id ?? ''
    libraryView.value = requestedDiagram?.ownerId !== user.value.id && requestedDiagram?.visibility === 'public' ? 'public' : 'mine'
    legacyDiagrams.value = await readLocalDiagrams()
  } catch (error) {
    appError.value = getErrorMessage(error)
  } finally {
    cloudReady.value = true
  }
}

async function refreshImageUrls() {
  if (!supabase || !user.value || !cloudReady.value) return
  for (const diagram of diagrams.value) {
    const { data } = await supabase.storage.from(storageBucket).createSignedUrl(diagram.imagePath, 60 * 60 * 24)
    if (data?.signedUrl) diagram.image = data.signedUrl
  }
}

async function handleAuth() {
  if (!supabase) return
  authBusy.value = true
  authMessage.value = ''
  appError.value = ''
  try {
    if (authMode.value === 'signup') {
      const { data, error } = await supabase.auth.signUp({ email: authEmail.value, password: authPassword.value })
      if (error) throw error
      if (!data.session) authMessage.value = 'Check your email for a confirmation link, then sign in.'
      else authMessage.value = 'Your account is ready.'
    } else {
      const { error } = await supabase.auth.signInWithPassword({ email: authEmail.value, password: authPassword.value })
      if (error) throw error
    }
  } catch (error) {
    authMessage.value = getErrorMessage(error)
  } finally {
    authBusy.value = false
  }
}

async function signOut() {
  if (!supabase) return
  const { error } = await supabase.auth.signOut()
  if (error) appError.value = error.message
}

function openUpload() {
  replacingImage.value = false
  imageInput.value?.click()
}

function replaceImage() {
  replacingImage.value = true
  imageInput.value?.click()
}

function makeImagePath(diagramId: string, fileName: string) {
  const safeName = fileName.replace(/[^\w.-]+/g, '_')
  return `${user.value?.id}/${diagramId}/${crypto.randomUUID()}-${safeName}`
}

async function uploadImage(file: File, diagramId: string) {
  if (!supabase || !user.value) throw new Error('Sign in before uploading diagrams.')
  const imagePath = makeImagePath(diagramId, file.name)
  const { error } = await supabase.storage.from(storageBucket).upload(imagePath, file, {
    contentType: file.type,
    upsert: false,
  })
  if (error) throw error
  return imagePath
}

async function handleFile(event: Event) {
  const input = event.target as HTMLInputElement
  const file = input.files?.[0]
  input.value = ''
  if (!file || !file.type.startsWith('image/') || !supabase || !user.value) return

  uploadBusy.value = true
  appError.value = ''
  try {
    if (replacingImage.value && activeDiagram.value) {
      const diagram = activeDiagram.value
      const previousPath = diagram.imagePath
      const imagePath = await uploadImage(file, diagram.id)
      const { error } = await supabase
        .from('diagrams')
        .update({ image_path: imagePath, updated_at: new Date().toISOString() })
        .eq('id', diagram.id)
        .eq('user_id', user.value.id)
      if (error) {
        await supabase.storage.from(storageBucket).remove([imagePath])
        throw error
      }
      const { data: signedImage, error: signedError } = await supabase.storage
        .from(storageBucket)
        .createSignedUrl(imagePath, 60 * 60 * 24)
      if (signedError) throw signedError
      diagram.imagePath = imagePath
      diagram.image = signedImage.signedUrl
      diagram.updatedAt = Date.now()
      await supabase.storage.from(storageBucket).remove([previousPath])
      replacingImage.value = false
      saveState.value = 'saved'
      return
    }

    const title = file.name.replace(/\.[^.]+$/, '').replace(/[_-]+/g, ' ') || 'Untitled diagram'
    const diagramId = crypto.randomUUID()
    const imagePath = await uploadImage(file, diagramId)
    const { error } = await supabase.from('diagrams').insert({
      id: diagramId,
      user_id: user.value.id,
      title,
      image_path: imagePath,
      folder_id: null,
      tags: [],
      visibility: 'private',
    })
    if (error) {
      await supabase.storage.from(storageBucket).remove([imagePath])
      throw error
    }
    const { data: signedImage, error: signedError } = await supabase.storage
      .from(storageBucket)
      .createSignedUrl(imagePath, 60 * 60 * 24)
    if (signedError) throw signedError
    diagrams.value.unshift({
      id: diagramId,
      ownerId: user.value.id,
      title,
      image: signedImage.signedUrl,
      imagePath,
      folderId: null,
      folderName: '',
      tags: [],
      visibility: 'private',
      structures: [],
      updatedAt: Date.now(),
    })
    selectedId.value = diagramId
    libraryView.value = 'mine'
    mode.value = 'edit'
    resetStudy()
    saveState.value = 'saved'
  } catch (error) {
    appError.value = getErrorMessage(error)
  } finally {
    uploadBusy.value = false
  }
}

async function persistDiagram(diagram: Diagram) {
  if (!supabase || !user.value || diagram.ownerId !== user.value.id || !cloudReady.value) return
  try {
    const updatedAt = new Date().toISOString()
    const { error: diagramError } = await supabase
      .from('diagrams')
      .update({
        title: diagram.title,
        folder_id: diagram.folderId,
        tags: diagram.tags,
        visibility: diagram.visibility,
        updated_at: updatedAt,
      })
      .eq('id', diagram.id)
      .eq('user_id', user.value.id)
    if (diagramError) throw diagramError
    if (diagram.structures.length) {
      const { error: structuresError } = await supabase.from('structures').upsert(
        diagram.structures.map((structure, position) => ({
          id: structure.id,
          name: structure.name,
          x: structure.x,
          y: structure.y,
          label_x: getLabelPosition(structure).x,
          label_y: getLabelPosition(structure).y,
          target_type: structure.targetType ?? 'point',
          radius: structure.targetType === 'circle' ? structure.radius : null,
          diagram_id: diagram.id,
          position,
        })),
      )
      if (structuresError) throw structuresError
    }
    saveState.value = 'saved'
  } catch (error) {
    saveState.value = 'error'
    appError.value = `Could not save changes: ${getErrorMessage(error)}`
  }
}

function setTitle(value: string) {
  if (activeDiagram.value && canEditActive.value) {
    activeDiagram.value.title = value
    activeDiagram.value.updatedAt = Date.now()
  }
}

function setDiagramFolder(folderId: string) {
  if (!activeDiagram.value || !canEditActive.value) return
  activeDiagram.value.folderId = folderId || null
  activeDiagram.value.folderName = folders.value.find((folder) => folder.id === folderId)?.name ?? ''
}

async function createFolderRecord(name: string) {
  if (!supabase || !user.value) throw new Error('Sign in to create a folder.')
  const { data, error } = await supabase
    .from('folders')
    .insert({ user_id: user.value.id, name })
    .select('id, name')
    .single()
  if (error) throw error
  folders.value.push(data)
  return data as Folder
}

async function createFolder() {
  const name = newFolderName.value.trim()
  if (!name || !supabase || !user.value) return
  folderBusy.value = true
  appError.value = ''
  try {
    await createFolderRecord(name)
    newFolderName.value = ''
    newFolderOpen.value = false
    folderFilter.value = ''
  } catch (error) {
    appError.value = getErrorMessage(error)
  } finally {
    folderBusy.value = false
  }
}

async function openNewFolder() {
  newFolderName.value = ''
  newFolderOpen.value = true
  await nextTick()
  newFolderNameInput.value?.focus()
}

async function getOrCreateFolderId(name: string) {
  const normalizedName = name.trim()
  if (!normalizedName) return null
  const existing = folders.value.find((folder) => folder.name.toLocaleLowerCase() === normalizedName.toLocaleLowerCase())
  if (existing) return existing.id
  return (await createFolderRecord(normalizedName)).id
}

function addTag() {
  if (!activeDiagram.value || !canEditActive.value) return
  const tag = tagDraft.value.trim().replace(/^#/, '')
  if (tag && !activeDiagram.value.tags.some((item) => item.toLocaleLowerCase() === tag.toLocaleLowerCase())) {
    activeDiagram.value.tags.push(tag)
  }
  tagDraft.value = ''
}

function removeTag(tag: string) {
  if (!activeDiagram.value || !canEditActive.value) return
  activeDiagram.value.tags = activeDiagram.value.tags.filter((item) => item !== tag)
}

async function copyShareLink() {
  if (!activeDiagram.value) return
  const url = new URL(window.location.href)
  url.searchParams.set('diagram', activeDiagram.value.id)
  try {
    await navigator.clipboard.writeText(url.toString())
    shareMessage.value = 'Share link copied'
  } catch {
    shareMessage.value = url.toString()
  }
  window.setTimeout(() => { shareMessage.value = '' }, 3500)
}

function openDiagram(diagram: Diagram) {
  selectedId.value = diagram.id
  mode.value = 'edit'
  resetStudy()
  const url = new URL(window.location.href)
  url.searchParams.set('diagram', diagram.id)
  window.history.replaceState({}, '', url)
}

function setStructureName(structure: Structure, value: string) {
  if (!canEditActive.value) return
  structure.name = value
  if (activeDiagram.value) activeDiagram.value.updatedAt = Date.now()
}

async function onDiagramClick(event: MouseEvent) {
  if (!placing.value || !activeDiagram.value || labelTargetType.value !== 'point') return
  const stage = event.currentTarget as HTMLElement
  const bounds = stage.getBoundingClientRect()
  const x = clampCoordinate(((event.clientX - bounds.left) / bounds.width) * 100)
  const y = clampCoordinate(((event.clientY - bounds.top) / bounds.height) * 100)
  pendingPoint.value = {
    x,
    y,
    labelX: getDefaultLabelX(x),
    labelY: clampCoordinate(y - 5),
    targetType: 'point',
    radius: null,
  }
  structureName.value = ''
  await nextTick()
  structureNameInput.value?.focus()
}

function clampCoordinate(value: number) {
  return Math.max(2, Math.min(98, value))
}

function getDefaultLabelX(x: number) {
  return clampCoordinate(x + (x > 76 ? -9 : 9))
}

function getStageCoordinates(clientX: number, clientY: number) {
  const bounds = diagramStage.value?.getBoundingClientRect()
  if (!bounds) return { x: 0, y: 0 }
  return {
    x: clampCoordinate(((clientX - bounds.left) / bounds.width) * 100),
    y: clampCoordinate(((clientY - bounds.top) / bounds.height) * 100),
  }
}

function startCircle(event: PointerEvent) {
  if (!placing.value || !canEditActive.value || labelTargetType.value !== 'circle' || event.button !== 0) return
  event.preventDefault()
  const center = getStageCoordinates(event.clientX, event.clientY)
  circleStart.value = center
  circleDraft.value = { ...center, radius: 0.5 }
  ;(event.currentTarget as HTMLElement).setPointerCapture(event.pointerId)
}

function resizeCircle(event: PointerEvent) {
  if (!circleStart.value || !diagramStage.value) return
  const bounds = diagramStage.value.getBoundingClientRect()
  const centerX = (circleStart.value.x / 100) * bounds.width
  const centerY = (circleStart.value.y / 100) * bounds.height
  const distance = Math.hypot(event.clientX - bounds.left - centerX, event.clientY - bounds.top - centerY)
  const maxRadius = Math.min(centerX, bounds.width - centerX, centerY, bounds.height - centerY)
  const radius = Math.min(distance, maxRadius, bounds.width * 0.25)
  circleDraft.value = { ...circleStart.value, radius: Math.max(0.25, (radius / bounds.width) * 100) }
}

async function finishCircle(event: PointerEvent) {
  if (!circleStart.value || !circleDraft.value) return
  resizeCircle(event)
  const draft = circleDraft.value
  const radius = Math.max(0.25, draft.radius)
  const labelX = clampCoordinate(draft.x + (draft.x > 76 ? -(radius + 3) : radius + 3))
  pendingPoint.value = {
    x: draft.x,
    y: draft.y,
    labelX,
    labelY: clampCoordinate(draft.y - radius - 3),
    targetType: 'circle',
    radius,
  }
  circleStart.value = null
  circleDraft.value = null
  structureName.value = ''
  await nextTick()
  structureNameInput.value?.focus()
}

function getLabelPosition(structure: Pick<Structure, 'x' | 'y' | 'labelX' | 'labelY'>) {
  return {
    x: structure.labelX ?? getDefaultLabelX(structure.x),
    y: structure.labelY ?? clampCoordinate(structure.y - 5),
  }
}

function startLabelDrag(event: PointerEvent, structure: Structure) {
  if (event.button !== 0 || placing.value || !canEditActive.value) return
  event.preventDefault()
  draggingLabelId.value = structure.id
  ;(event.currentTarget as HTMLElement).setPointerCapture(event.pointerId)
}

function moveLabel(event: PointerEvent) {
  const structure = activeDiagram.value?.structures.find((item) => item.id === draggingLabelId.value)
  const stage = diagramStage.value
  if (!structure || !stage) return
  const bounds = stage.getBoundingClientRect()
  const label = event.currentTarget as HTMLElement
  const halfWidth = (label.offsetWidth / bounds.width) * 50
  const halfHeight = (label.offsetHeight / bounds.height) * 50
  structure.labelX = Math.max(halfWidth, Math.min(100 - halfWidth, ((event.clientX - bounds.left) / bounds.width) * 100))
  structure.labelY = Math.max(halfHeight, Math.min(100 - halfHeight, ((event.clientY - bounds.top) / bounds.height) * 100))
}

function endLabelDrag() {
  draggingLabelId.value = null
}

function cancelCircle() {
  circleStart.value = null
  circleDraft.value = null
}

function addStructure() {
  if (!activeDiagram.value || !pendingPoint.value || !structureName.value.trim()) return
  activeDiagram.value.structures.push({
    id: crypto.randomUUID(),
    name: structureName.value.trim(),
    ...pendingPoint.value,
  })
  activeDiagram.value.updatedAt = Date.now()
  pendingPoint.value = null
  structureName.value = ''
}

async function removeStructure(id: string) {
  if (!activeDiagram.value || !supabase) return
  const diagram = activeDiagram.value
  const { error } = await supabase.from('structures').delete().eq('id', id).eq('diagram_id', diagram.id)
  if (error) {
    appError.value = `Could not remove structure: ${error.message}`
    return
  }
  diagram.structures = diagram.structures.filter((item) => item.id !== id)
  diagram.updatedAt = Date.now()
}

function startStudy() {
  if (!activeDiagram.value?.structures.length) return
  resetStudy()
  mode.value = 'study'
}

function resetStudy() {
  answers.value = {}
  checked.value = false
}

function isCorrect(structure: Structure) {
  return Boolean(structure.name.trim()) && answers.value[structure.id]?.trim().toLocaleLowerCase() === structure.name.trim().toLocaleLowerCase()
}

async function deleteDiagram() {
  if (!activeDiagram.value || !supabase || !user.value) return
  const diagram = activeDiagram.value
  const { error } = await supabase.from('diagrams').delete().eq('id', diagram.id).eq('user_id', user.value.id)
  if (error) {
    appError.value = `Could not delete diagram: ${error.message}`
    return
  }
  const { error: storageError } = await supabase.storage.from(storageBucket).remove([diagram.imagePath])
  if (storageError) appError.value = `Diagram deleted, but its image could not be removed: ${storageError.message}`
  diagrams.value = diagrams.value.filter((item) => item.id !== diagram.id)
  selectedId.value = diagrams.value[0]?.id ?? ''
  mode.value = 'edit'
  resetStudy()
}

async function importLocalDiagrams() {
  if (!supabase || !user.value || !legacyDiagrams.value.length) return
  importBusy.value = true
  appError.value = ''
  try {
    while (legacyDiagrams.value.length) {
      const localDiagram = legacyDiagrams.value[0]
      if (!localDiagram) break
      const imageBlob = await (await fetch(localDiagram.image)).blob()
      const extension = imageBlob.type.split('/')[1] || 'png'
      const imageFile = new File([imageBlob], `${localDiagram.title || 'diagram'}.${extension}`, { type: imageBlob.type || 'image/png' })
      const imagePath = await uploadImage(imageFile, localDiagram.id)
      const folderId = await getOrCreateFolderId(localDiagram.folderName ?? '')
      const { error: diagramError } = await supabase.from('diagrams').insert({
        id: localDiagram.id,
        user_id: user.value.id,
        title: localDiagram.title,
        image_path: imagePath,
        folder_id: folderId,
        tags: localDiagram.tags ?? [],
        visibility: localDiagram.visibility ?? 'private',
      })
      if (diagramError) {
        await supabase.storage.from(storageBucket).remove([imagePath])
        throw diagramError
      }
      if (localDiagram.structures.length) {
        const { error: structuresError } = await supabase.from('structures').insert(
          localDiagram.structures.map((structure, position) => ({
            id: structure.id,
            name: structure.name,
            x: structure.x,
            y: structure.y,
            label_x: getLabelPosition(structure).x,
            label_y: getLabelPosition(structure).y,
            target_type: structure.targetType ?? 'point',
            radius: structure.targetType === 'circle' ? structure.radius : null,
            diagram_id: localDiagram.id,
            position,
          })),
        )
        if (structuresError) {
          await supabase.from('diagrams').delete().eq('id', localDiagram.id)
          await supabase.storage.from(storageBucket).remove([imagePath])
          throw structuresError
        }
      }
      legacyDiagrams.value.shift()
      await writeLocalDiagrams(legacyDiagrams.value)
    }
    await loadCloudDiagrams()
  } catch (error) {
    appError.value = `Import stopped. Diagrams already imported are safe; remaining local diagrams are still here. ${getErrorMessage(error)}`
  } finally {
    importBusy.value = false
  }
}

function formatDate(timestamp: number) {
  return new Intl.DateTimeFormat('en', { month: 'short', day: 'numeric' }).format(timestamp)
}

function getErrorMessage(error: unknown) {
  return error instanceof Error ? error.message : 'An unexpected error occurred.'
}

function onDrop(event: DragEvent) {
  const file = event.dataTransfer?.files[0]
  if (!file || !file.type.startsWith('image/')) return
  const input = imageInput.value
  if (!input) return
  const transfer = new DataTransfer()
  transfer.items.add(file)
  input.files = transfer.files
  input.dispatchEvent(new Event('change', { bubbles: true }))
}
</script>

<template>
  <div class="app-shell">
    <main v-if="!isSupabaseConfigured || !user" class="auth-screen">
      <section class="auth-card">
        <a class="brand auth-brand" href="#" @click.prevent>
          <span class="brand-mark" aria-hidden="true">
            <svg viewBox="0 0 36 36" fill="none"><path d="M18 4.5v27M4.5 18h27M8.45 8.45l19.1 19.1m0-19.1-19.1 19.1" stroke="currentColor" stroke-width="1.6"/><circle cx="18" cy="18" r="5.25" stroke="currentColor" stroke-width="1.6"/></svg>
          </span>
          <span class="brand-name">FIELDNOTES<span>ANATOMY STUDY</span></span>
        </a>
        <template v-if="!isSupabaseConfigured">
          <div class="eyebrow"><span class="eyebrow-line"></span> CLOUD LIBRARY SETUP</div>
          <h1>Connect your<br /><em>study space.</em></h1>
          <p class="auth-description">Add your Supabase project details to enable secure accounts and synced diagrams.</p>
          <ol class="setup-steps">
            <li><span>01</span><p>Create a Supabase project and run <code>supabase/schema.sql</code> in its SQL editor.</p></li>
            <li><span>02</span><p>Copy <code>.env.example</code> to <code>.env.local</code> and add your project URL and anon key.</p></li>
            <li><span>03</span><p>Restart the dev server to load the new environment variables.</p></li>
          </ol>
          <a class="setup-link" href="https://supabase.com/dashboard" target="_blank" rel="noreferrer">Open Supabase dashboard <span>↗</span></a>
        </template>
        <template v-else>
          <div class="eyebrow"><span class="eyebrow-line"></span> YOUR PRIVATE STUDY LIBRARY</div>
          <h1>{{ authMode === 'signin' ? 'Welcome back.' : 'Make it yours.' }}<br /><em>{{ authMode === 'signin' ? 'Pick up where you left off.' : 'Create your account.' }}</em></h1>
          <p class="auth-description">Your diagrams and labels sync securely to your account.</p>
          <form class="auth-form" @submit.prevent="handleAuth">
            <label for="auth-email">EMAIL ADDRESS</label>
            <input id="auth-email" v-model="authEmail" type="email" autocomplete="email" required placeholder="you@example.com" />
            <label for="auth-password">PASSWORD</label>
            <input id="auth-password" v-model="authPassword" :autocomplete="authMode === 'signin' ? 'current-password' : 'new-password'" type="password" minlength="8" required placeholder="At least 8 characters" />
            <p v-if="authMessage" class="auth-message">{{ authMessage }}</p>
            <p v-if="appError" class="auth-error">{{ appError }}</p>
            <button class="primary-button auth-submit" type="submit" :disabled="authBusy">{{ authBusy ? 'Please wait…' : authMode === 'signin' ? 'Sign in' : 'Create account' }}</button>
          </form>
          <button class="auth-switch" type="button" @click="authMode = authMode === 'signin' ? 'signup' : 'signin'; authMessage = ''; appError = ''">
            {{ authMode === 'signin' ? 'New to Fieldnotes? Create an account' : 'Already have an account? Sign in' }}
          </button>
        </template>
      </section>
      <div class="auth-illustration" aria-hidden="true">
        <div class="art-topline"><span>FIELDNOTES / VOL. 01</span><span>STUDY PLATE</span></div>
        <div class="auth-plate">
          <svg class="anatomy-sketch" viewBox="0 0 320 390" fill="none">
            <path d="M132 39c-9 6-14 20-13 38l4 32-20 19c-18 17-29 42-33 73l-10 82 19 3 17-71 9-32 5 54-6 107h27l12-97 7-54 7 54 12 97h27l-6-107 5-54 9 32 17 71 19-3-10-82c-4-31-15-56-33-73l-20-19 4-32c1-18-4-32-13-38-6 12-14 19-20 19s-14-7-20-19Z" stroke="currentColor" stroke-width="1.35"/>
            <path d="M119 108c11 8 25 12 41 12s30-4 41-12M105 131c14 10 32 15 55 15s41-5 55-15M93 164c19 11 41 16 67 16s48-5 67-16M83 198c24 10 49 15 77 15s53-5 77-15M81 229c23 8 49 12 79 12s56-4 79-12M80 258c25 7 51 10 80 10s55-3 80-10" stroke="currentColor" stroke-width="1"/>
            <path d="M145 121c-8 14-11 26-9 38m39-38c8 14 11 26 9 38M140 168c-4 18-2 36 6 52m34-52c4 18 2 36-6 52M146 236l-5 54m33-54 5 54" stroke="currentColor" stroke-width="1"/>
            <circle cx="160" cy="167" r="12" stroke="currentColor" stroke-width="1.2"/><path d="M154 167h12m-6-6v12M217 151h56l22-22M91 202H42l-20 20M218 236h43l24 24" stroke="currentColor" stroke-width=".9" stroke-dasharray="3 3"/>
          </svg>
          <span class="auth-plate-label">ANTERIOR / FIG. 01</span>
        </div>
        <div class="art-bottomline"><span>OBSERVE · LABEL · RECALL</span><span>FIELDNOTES</span></div>
      </div>
    </main>

    <template v-else>
    <aside class="sidebar">
      <a class="brand" href="#" @click.prevent="mode = 'edit'">
        <span class="brand-mark" aria-hidden="true">
          <svg viewBox="0 0 36 36" fill="none"><path d="M18 4.5v27M4.5 18h27M8.45 8.45l19.1 19.1m0-19.1-19.1 19.1" stroke="currentColor" stroke-width="1.6"/><circle cx="18" cy="18" r="5.25" stroke="currentColor" stroke-width="1.6"/></svg>
        </span>
        <span class="brand-name">FIELDNOTES<span>ANATOMY STUDY</span></span>
      </a>

      <button class="new-button" type="button" :disabled="uploadBusy" @click="openUpload">
        <span class="plus">+</span> New diagram
      </button>

      <div class="library-heading">
        <span>{{ libraryView === 'mine' ? 'Your library' : 'Public library' }}</span><span class="count">{{ visibleDiagrams.length }}</span>
      </div>
      <div class="library-tabs" role="tablist" aria-label="Diagram library">
        <button type="button" role="tab" :aria-selected="libraryView === 'mine'" :class="{ active: libraryView === 'mine' }" @click="libraryView = 'mine'; folderFilter = ''; tagFilter = ''">My diagrams</button>
        <button type="button" role="tab" :aria-selected="libraryView === 'public'" :class="{ active: libraryView === 'public' }" @click="libraryView = 'public'; folderFilter = ''; tagFilter = ''">Public</button>
      </div>
      <button v-if="libraryView === 'mine'" class="new-folder-button" type="button" @click="openNewFolder"><span>＋</span> New Folder</button>
      <label v-if="libraryView === 'mine' && availableFolders.length" class="folder-filter-label">
        <span>FOLDER</span>
        <select v-model="folderFilter" aria-label="Filter by folder">
          <option value="">All folders</option>
          <option v-for="folder in availableFolders" :key="folder.id" :value="folder.id">{{ folder.name }}</option>
        </select>
      </label>
      <label v-if="availableTags.length" class="folder-filter-label">
        <span>TOPIC</span>
        <select v-model="tagFilter" aria-label="Filter by tag">
          <option value="">All topics</option>
          <option v-for="tag in availableTags" :key="tag" :value="tag">{{ tag }}</option>
        </select>
      </label>
      <nav class="diagram-list" aria-label="Saved diagrams">
        <button
          v-for="diagram in visibleDiagrams"
          :key="diagram.id"
          class="diagram-link"
          :class="{ active: selectedId === diagram.id }"
          type="button"
          @click="openDiagram(diagram)"
        >
          <span class="thumbnail"><img :src="diagram.image" :alt="''" /></span>
          <span class="diagram-link-copy">
            <span class="diagram-link-title">{{ diagram.title }}</span>
            <span class="diagram-link-meta">{{ diagram.structures.length }} labels · {{ libraryView === 'mine' ? diagram.folderName || 'Unfiled' : 'Shared publicly' }}</span>
          </span>
          <span class="active-dot"></span>
        </button>
        <div v-if="!visibleDiagrams.length" class="library-empty">{{ libraryView === 'mine' ? 'Your saved diagrams will appear here.' : 'No public diagrams yet.' }}</div>
      </nav>

      <div class="sidebar-bottom">
        <span class="save-indicator" :class="`save-${saveState}`"><span></span>{{ saveState === 'saving' ? 'Syncing changes…' : saveState === 'error' ? 'Sync needs attention' : 'Saved to your account' }}</span>
        <span class="sidebar-note">A quiet place to learn<br />the parts by heart.</span>
      </div>
    </aside>

    <main class="main-area">
      <header class="topbar">
        <div class="breadcrumbs"><span>STUDY DESK</span><i>/</i><span>{{ mode === 'study' ? 'PRACTICE' : 'DIAGRAMS' }}</span></div>
        <div class="topbar-right">
          <span class="local-tag"><span></span> SYNCED LIBRARY</span>
          <button class="avatar" :title="`Sign out ${user.email}`" :aria-label="`Sign out ${user.email}`" type="button" @click="signOut">{{ user.email?.[0]?.toUpperCase() ?? 'A' }}</button>
        </div>
      </header>

      <div class="mobile-library-tabs" role="tablist" aria-label="Diagram library">
        <button type="button" role="tab" :aria-selected="libraryView === 'mine'" :class="{ active: libraryView === 'mine' }" @click="libraryView = 'mine'; folderFilter = ''; tagFilter = ''">My diagrams</button>
        <button type="button" role="tab" :aria-selected="libraryView === 'public'" :class="{ active: libraryView === 'public' }" @click="libraryView = 'public'; folderFilter = ''; tagFilter = ''">Public library</button>
        <button v-if="libraryView === 'mine'" class="new-folder-button mobile-new-folder" type="button" @click="openNewFolder"><span>＋</span> New Folder</button>
        <label v-if="libraryView === 'mine' && availableFolders.length" class="mobile-filter"><span>Folder</span><select v-model="folderFilter"><option value="">All folders</option><option v-for="folder in availableFolders" :key="folder.id" :value="folder.id">{{ folder.name }}</option></select></label>
        <label v-if="availableTags.length" class="mobile-filter"><span>Topic</span><select v-model="tagFilter"><option value="">All topics</option><option v-for="tag in availableTags" :key="tag" :value="tag">{{ tag }}</option></select></label>
      </div>

      <div v-if="appError" class="app-alert" role="alert"><span>{{ appError }}</span><button type="button" aria-label="Dismiss error" @click="appError = ''">×</button></div>
      <div v-if="legacyDiagrams.length" class="import-banner">
        <div><strong>{{ legacyDiagrams.length }} locally saved {{ legacyDiagrams.length === 1 ? 'diagram' : 'diagrams' }} found</strong><small>Import them into your account? The local copies stay until each upload succeeds.</small></div>
        <button class="primary-button" type="button" :disabled="importBusy" @click="importLocalDiagrams">{{ importBusy ? 'Importing…' : 'Import diagrams' }}</button>
      </div>
      <div v-if="!cloudReady" class="loading-state"><span class="pulse-dot"></span> Loading your library…</div>

      <template v-if="cloudReady && activeDiagram">
        <section class="page-heading">
          <div>
            <div class="eyebrow"><span class="eyebrow-line"></span> YOUR STUDY MATERIAL</div>
            <input
              v-if="mode === 'edit' && canEditActive"
              class="title-input"
              :value="activeDiagram.title"
              aria-label="Diagram title"
              @input="setTitle(($event.target as HTMLInputElement).value)"
            />
            <h1 v-else class="page-title">{{ activeDiagram.title }}<span v-if="mode === 'study'" class="study-label">Practice</span></h1>
            <p class="subtitle">{{ mode === 'study' ? 'Name each label from memory.' : 'Build a visual study sheet, one label at a time.' }}</p>
          </div>
          <div class="heading-actions">
            <template v-if="mode === 'edit' && canEditActive">
              <button class="text-button" type="button" @click="deleteDiagram">Delete diagram</button>
              <button class="primary-button" type="button" :disabled="!activeDiagram.structures.length" @click="startStudy">
                <svg viewBox="0 0 20 20" fill="none" aria-hidden="true"><path d="M7 4.5 13 10l-6 5.5V4.5Z" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round"/></svg>
                Start practice
              </button>
            </template>
            <template v-else-if="mode === 'edit'">
              <button class="primary-button" type="button" :disabled="!activeDiagram.structures.length" @click="startStudy">Practice this diagram</button>
            </template>
            <template v-else>
              <button class="text-button" type="button" @click="mode = 'edit'; resetStudy()">Back to edit</button>
              <button class="primary-button" type="button" @click="checked ? resetStudy() : checked = true">
                {{ checked ? 'Try again' : 'Check answers' }}
              </button>
            </template>
          </div>
        </section>

        <section class="organization-strip" aria-label="Diagram organization and sharing">
          <template v-if="canEditActive">
            <label class="metadata-field folder-field">
              <span>FOLDER</span>
              <select :value="activeDiagram.folderId ?? ''" aria-label="Place diagram in folder" @change="setDiagramFolder(($event.target as HTMLSelectElement).value)">
                <option value="">Unfiled</option>
                <option v-for="folder in availableFolders" :key="folder.id" :value="folder.id">{{ folder.name }}</option>
              </select>
            </label>
            <label class="metadata-field visibility-field">
              <span>VISIBILITY</span>
              <select v-model="activeDiagram.visibility" aria-label="Diagram visibility">
                <option value="private">Private</option>
                <option value="public">Public</option>
              </select>
            </label>
            <div class="metadata-field tags-field">
              <span>TOPIC TAGS</span>
              <div class="tag-list">
                <span v-for="tag in activeDiagram.tags" :key="tag" class="topic-tag">{{ tag }}<button type="button" :aria-label="`Remove ${tag} tag`" @click="removeTag(tag)">×</button></span>
                <form class="tag-entry" @submit.prevent="addTag">
                  <input v-model="tagDraft" maxlength="30" aria-label="Add a topic tag" placeholder="Add a tag" />
                  <button type="submit" :disabled="!tagDraft.trim()" aria-label="Add tag">＋</button>
                </form>
              </div>
            </div>
          </template>
          <div v-else class="public-readonly"><span class="public-icon">↗</span><span><strong>Public diagram</strong><small>Shared by another learner · Read only</small></span><div class="public-tag-list"><span v-for="tag in activeDiagram.tags" :key="tag" class="topic-tag">{{ tag }}</span></div></div>
          <div v-if="activeDiagram.visibility === 'public'" class="share-action">
            <button class="text-button share-button" type="button" @click="copyShareLink">
              <svg viewBox="0 0 20 20" fill="none" aria-hidden="true"><path d="M8 12 12 8m-5.5 6H5a3 3 0 0 1 0-6h2m6 4h2a3 3 0 0 0 0-6h-1.5" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/></svg>
              Copy share link
            </button>
            <span v-if="shareMessage" class="share-message">{{ shareMessage }}</span>
          </div>
        </section>

        <div v-if="mode === 'study' && checked" class="result-banner" :class="{ complete: correctCount === activeDiagram.structures.length }">
          <span class="result-mark">{{ correctCount === activeDiagram.structures.length ? '✓' : '·' }}</span>
          <span><strong>{{ correctCount }} of {{ activeDiagram.structures.length }} correct</strong><small>{{ correctCount === activeDiagram.structures.length ? 'Excellent recall. Keep it fresh with another round.' : 'Review the missed labels, then give it another go.' }}</small></span>
          <button type="button" @click="resetStudy">Clear answers</button>
        </div>

        <section class="workbench" :class="{ 'is-study': mode === 'study' }">
          <div class="image-column">
            <div class="canvas-toolbar">
              <div class="canvas-caption"><span class="caption-icon">⌗</span><span>{{ mode === 'study' ? 'IDENTIFY THE CALLOUTS' : 'DIAGRAM CANVAS' }}</span></div>
              <div class="canvas-actions">
                <span v-if="mode === 'edit'" class="image-dimensions">{{ activeDiagram.structures.length }} {{ activeDiagram.structures.length === 1 ? 'callout' : 'callouts' }}</span>
                <button v-if="mode === 'edit' && canEditActive" class="icon-button" title="Replace diagram image" aria-label="Replace diagram image" type="button" :disabled="uploadBusy" @click="replaceImage">
                  <svg viewBox="0 0 20 20" fill="none"><path d="M10 13V3m0 0L6.5 6.5M10 3l3.5 3.5M4 11.5v4h12v-4" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"/></svg>
                </button>
              </div>
            </div>
            <div
              class="diagram-stage"
              ref="diagramStage"
              :class="{ placing, 'placing-circle': placing && labelTargetType === 'circle' }"
              @click="onDiagramClick"
              @pointerdown="startCircle"
              @pointermove="resizeCircle"
              @pointerup="finishCircle"
              @pointercancel="cancelCircle"
              @dragover.prevent
              @drop.prevent="onDrop"
            >
              <img class="diagram-image" :src="activeDiagram.image" :alt="activeDiagram.title" draggable="false" />
              <svg class="leader-lines" aria-hidden="true">
                <line
                  v-for="(structure, index) in activeDiagram.structures"
                  :key="`line-${structure.id}`"
                  :x1="`${structure.x}%`"
                  :y1="`${structure.y}%`"
                  :x2="`${getLabelPosition(structure).x}%`"
                  :y2="`${getLabelPosition(structure).y}%`"
                />
              </svg>
              <template v-for="(structure, index) in activeDiagram.structures" :key="`target-${structure.id}`">
                <div
                  v-if="structure.targetType === 'circle'"
                  class="target-circle"
                  :style="{ left: `${structure.x}%`, top: `${structure.y}%`, width: `${(structure.radius ?? 2) * 2}%` }"
                  aria-hidden="true"
                ></div>
                <div v-else class="callout-target" :style="{ left: `${structure.x}%`, top: `${structure.y}%` }" aria-hidden="true">
                  <span class="target-dot"></span>
                </div>
              </template>
              <template v-for="(structure, index) in activeDiagram.structures" :key="`label-${structure.id}`">
                <button
                  v-if="mode === 'edit' && canEditActive && !placing"
                  class="callout-number"
                  :class="{ dragging: draggingLabelId === structure.id }"
                  :style="{ left: `${getLabelPosition(structure).x}%`, top: `${getLabelPosition(structure).y}%` }"
                  type="button"
                  :aria-label="`Drag label ${structure.name} to reposition it`"
                  :title="`Drag to move ${structure.name}`"
                  @pointerdown.stop="startLabelDrag($event, structure)"
                  @pointermove.stop="moveLabel"
                  @pointerup.stop="endLabelDrag"
                  @pointercancel.stop="endLabelDrag"
                  @lostpointercapture.stop="endLabelDrag"
                  @click.stop
                >
                  <span class="callout-index">{{ String(index + 1).padStart(2, '0') }}</span>
                  <span class="callout-label-name">{{ structure.name || 'Unnamed label' }}</span>
                </button>
                <span
                  v-else-if="mode === 'edit'"
                  class="callout-number"
                  :style="{ left: `${getLabelPosition(structure).x}%`, top: `${getLabelPosition(structure).y}%` }"
                >
                  <span class="callout-index">{{ String(index + 1).padStart(2, '0') }}</span>
                  <span class="callout-label-name">{{ structure.name || 'Unnamed label' }}</span>
                </span>
                <span
                  v-else
                  class="callout-number practice-number"
                  :style="{ left: `${getLabelPosition(structure).x}%`, top: `${getLabelPosition(structure).y}%` }"
                >{{ String(index + 1).padStart(2, '0') }}</span>
              </template>
              <div
                v-if="circleDraft"
                class="target-circle circle-draft"
                :style="{ left: `${circleDraft.x}%`, top: `${circleDraft.y}%`, width: `${circleDraft.radius * 2}%` }"
                aria-hidden="true"
              ></div>
              <div v-if="placing" class="placement-hint"><span>＋</span> {{ labelTargetType === 'point' ? 'Click a point to place the label' : 'Drag out a circle target' }}</div>
              <div v-if="!activeDiagram.structures.length && !placing" class="canvas-empty-tip">
                <span class="tip-cross">＋</span><span>Start with a label</span>
              </div>
            </div>
            <div class="canvas-footer">
              <span><span class="footer-dot"></span> {{ mode === 'study' ? 'Labels hidden for practice' : 'Changes save automatically' }}</span>
              <span>IMAGE STUDY SHEET</span>
            </div>
          </div>

          <aside class="structure-panel">
            <div class="panel-heading">
              <div><div class="eyebrow panel-eyebrow">{{ mode === 'study' ? 'RECALL' : 'LABELS' }}</div><h2>{{ mode === 'study' ? 'Your answers' : 'Your labels' }} <span>{{ activeDiagram.structures.length }}</span></h2></div>
            </div>

            <button
              v-if="mode === 'edit' && canEditActive"
              class="add-structure-button"
              :class="{ active: placing }"
              :aria-pressed="placing"
              type="button"
              @click="placing = !placing; pendingPoint = null"
            >
              <span>{{ placing ? '✓' : '＋' }}</span> {{ placing ? 'Done adding' : 'Add label' }}
            </button>
            <div v-if="mode === 'edit' && placing" class="placing-note"><span class="pulse-dot"></span> Choose a target type, then mark the diagram</div>
            <div v-if="mode === 'edit' && placing" class="target-type-picker" role="group" aria-label="Label target type">
              <button class="target-type-button" :class="{ selected: labelTargetType === 'point' }" type="button" :aria-pressed="labelTargetType === 'point'" @click="labelTargetType = 'point'; cancelCircle()">
                <span class="point-symbol"></span> Point
              </button>
              <button class="target-type-button" :class="{ selected: labelTargetType === 'circle' }" type="button" :aria-pressed="labelTargetType === 'circle'" @click="labelTargetType = 'circle'; cancelCircle()">
                <span class="circle-symbol"></span> Circle
              </button>
            </div>
            <div v-if="mode === 'edit' && placing" class="placement-help">
              {{ labelTargetType === 'point' ? 'Click the structure to set its point.' : 'Drag from the center outward to size a circle.' }}
            </div>

            <div v-if="activeDiagram.structures.length" class="structure-list">
              <div
                v-for="(structure, index) in activeDiagram.structures"
                :key="structure.id"
                class="structure-row"
                :class="{ 'answer-correct': mode === 'study' && checked && isCorrect(structure), 'answer-wrong': mode === 'study' && checked && !isCorrect(structure) }"
              >
                <span class="row-number">{{ String(index + 1).padStart(2, '0') }}</span>
                <div v-if="mode === 'edit' && canEditActive" class="structure-name-wrap">
                  <input :value="structure.name" class="structure-name" :aria-label="`Label ${index + 1} name`" placeholder="Name this label" @input="setStructureName(structure, ($event.target as HTMLInputElement).value)" />
                  <button class="remove-button" :aria-label="`Remove ${structure.name || 'label'}`" title="Remove label" type="button" @click="removeStructure(structure.id)">×</button>
                </div>
                <span v-else-if="mode === 'edit'" class="public-label-name">{{ structure.name }}</span>
                <div v-else class="answer-wrap">
                  <input
                    v-model="answers[structure.id]"
                    class="answer-input"
                    :class="{ correct: checked && isCorrect(structure), incorrect: checked && !isCorrect(structure) }"
                    :disabled="checked"
                    :placeholder="checked && !isCorrect(structure) ? structure.name : 'Type the label name'"
                    :aria-label="`Answer for callout ${index + 1}`"
                    @keyup.enter="!checked && (checked = true)"
                  />
                  <span v-if="checked" class="answer-feedback">{{ isCorrect(structure) ? 'Correct' : `Answer: ${structure.name}` }}</span>
                </div>
              </div>
            </div>
            <div v-else-if="mode === 'edit'" class="empty-structures">
              <span class="empty-structure-icon">↗</span>
              <p>No labels yet</p>
              <small>Add a label, then choose a point or draw a circle around its target.</small>
            </div>
            <div v-else class="empty-structures"><p>No labels to practice</p></div>

            <div v-if="mode === 'study' && !checked" class="practice-note"><span>↵</span> Press Enter to check your answers</div>
            <div v-if="mode === 'edit'" class="panel-tip"><span class="tip-star">✳</span><p><strong>Make it yours</strong><br />Place an arrow on the image, then name the label it points to.</p></div>
          </aside>
        </section>
      </template>

      <section v-else-if="cloudReady" class="welcome-screen" @dragover.prevent @drop.prevent="onDrop">
        <div class="welcome-copy">
          <div class="eyebrow"><span class="eyebrow-line"></span> A STUDY SPACE OF YOUR OWN</div>
          <h1>Learn the parts.<br /><em>Know them by heart.</em></h1>
          <p>Turn your anatomy diagrams into active recall practice. Add your own image, mark the labels, then test what you remember.</p>
          <button class="primary-button welcome-button" type="button" :disabled="uploadBusy" @click="openUpload"><span class="plus">+</span> {{ uploadBusy ? 'Uploading diagram…' : 'Upload your first diagram' }}</button>
          <div class="welcome-footnote"><span>↳</span> PNG, JPG, or WEBP · Saved privately in this browser</div>
        </div>
        <div class="welcome-art" aria-hidden="true">
          <div class="art-topline"><span>PLATE NO. 001</span><span>FIG. A</span></div>
          <div class="art-sheet">
            <svg class="anatomy-sketch" viewBox="0 0 320 390" fill="none">
              <path d="M132 39c-9 6-14 20-13 38l4 32-20 19c-18 17-29 42-33 73l-10 82 19 3 17-71 9-32 5 54-6 107h27l12-97 7-54 7 54 12 97h27l-6-107 5-54 9 32 17 71 19-3-10-82c-4-31-15-56-33-73l-20-19 4-32c1-18-4-32-13-38-6 12-14 19-20 19s-14-7-20-19Z" stroke="currentColor" stroke-width="1.35"/>
              <path d="M119 108c11 8 25 12 41 12s30-4 41-12M105 131c14 10 32 15 55 15s41-5 55-15M93 164c19 11 41 16 67 16s48-5 67-16M83 198c24 10 49 15 77 15s53-5 77-15M81 229c23 8 49 12 79 12s56-4 79-12M80 258c25 7 51 10 80 10s55-3 80-10" stroke="currentColor" stroke-width="1"/>
              <path d="M145 121c-8 14-11 26-9 38m39-38c8 14 11 26 9 38M140 168c-4 18-2 36 6 52m34-52c4 18 2 36-6 52M146 236l-5 54m33-54 5 54" stroke="currentColor" stroke-width="1"/>
              <circle cx="160" cy="167" r="12" stroke="currentColor" stroke-width="1.2"/><path d="M154 167h12m-6-6v12" stroke="currentColor" stroke-width="1"/>
              <path d="M217 151h56l22-22M91 202H42l-20 20M218 236h43l24 24" stroke="currentColor" stroke-width=".9" stroke-dasharray="3 3"/>
              <circle cx="295" cy="129" r="3" fill="currentColor"/><circle cx="22" cy="222" r="3" fill="currentColor"/><circle cx="285" cy="260" r="3" fill="currentColor"/>
            </svg>
            <span class="art-label label-one"><b>01</b> thoracic cavity</span>
            <span class="art-label label-two"><b>02</b> sternum</span>
            <span class="art-label label-three"><b>03</b> diaphragm</span>
            <span class="art-seal">F<br />N</span>
          </div>
          <div class="art-bottomline"><span>ANTERIOR VIEW</span><span>FIELDNOTES / ANATOMY</span></div>
        </div>
      </section>
    </main>

    <input ref="imageInput" class="visually-hidden" type="file" accept="image/*" @change="handleFile" />

    <div v-if="pendingPoint" class="modal-scrim" @click.self="pendingPoint = null">
      <form class="name-modal" @submit.prevent="addStructure">
        <div class="modal-kicker">NEW CALLOUT <span>{{ String((activeDiagram?.structures.length ?? 0) + 1).padStart(2, '0') }}</span></div>
        <h2>Name this label</h2>
        <p>Your arrow is placed. Name the label to add it to your study list.</p>
        <label class="modal-label" for="structure-name">LABEL NAME</label>
        <input id="structure-name" ref="structureNameInput" v-model="structureName" class="modal-input" placeholder="e.g. clavicle" />
        <div class="modal-actions">
          <button class="text-button" type="button" @click="pendingPoint = null">Cancel</button>
          <button class="primary-button" type="submit" :disabled="!structureName.trim()">Add label</button>
        </div>
      </form>
    </div>
    <div v-if="newFolderOpen" class="modal-scrim" @click.self="newFolderOpen = false">
      <form class="name-modal" @submit.prevent="createFolder">
        <div class="modal-kicker">YOUR LIBRARY <span>{{ folders.length }} FOLDERS</span></div>
        <h2>New Folder</h2>
        <p>Create a folder to group diagrams by course, system, or topic.</p>
        <label class="modal-label" for="new-folder-name">FOLDER NAME</label>
        <input id="new-folder-name" ref="newFolderNameInput" v-model="newFolderName" class="modal-input" maxlength="80" placeholder="e.g. Cardiovascular" />
        <div class="modal-actions">
          <button class="text-button" type="button" @click="newFolderOpen = false">Cancel</button>
          <button class="primary-button" type="submit" :disabled="!newFolderName.trim() || folderBusy">{{ folderBusy ? 'Creating…' : 'Create folder' }}</button>
        </div>
      </form>
    </div>
    </template>
  </div>
</template>

<style>
@import url('https://fonts.googleapis.com/css2?family=DM+Mono:wght@400;500&family=DM+Sans:wght@400;500;600;700&family=Newsreader:ital,opsz,wght@0,6..72,400;0,6..72,500;1,6..72,400;1,6..72,500&display=swap');

:root {
  font-family: 'DM Sans', sans-serif;
  color: #252c27;
  background: #f5f5f0;
  font-synthesis: none;
  text-rendering: optimizeLegibility;
  --ink: #252c27;
  --muted: #858b82;
  --line: #e5e7df;
  --paper: #fbfbf8;
  --green: #476b56;
  --green-dark: #345341;
  --mono: 'DM Mono', monospace;
  --serif: 'Newsreader', Georgia, serif;
}

* { box-sizing: border-box; }
body { margin: 0; min-width: 320px; min-height: 100vh; }
button, input { font: inherit; }
button { color: inherit; }
button:focus-visible, input:focus-visible { outline: 2px solid #6a9a77; outline-offset: 2px; }
.app-shell { display: flex; min-height: 100vh; background: #f5f5f0; }
.sidebar { width: 254px; flex: 0 0 254px; min-height: 100vh; display: flex; flex-direction: column; padding: 28px 17px 22px; background: #f0f1eb; border-right: 1px solid #e3e5dd; }
.brand { display: flex; align-items: center; gap: 11px; margin: 0 0 32px 7px; color: var(--ink); text-decoration: none; }
.brand-mark { display: grid; width: 36px; height: 36px; place-items: center; color: var(--green); }
.brand-mark svg { width: 36px; height: 36px; }
.brand-name { display: flex; flex-direction: column; font-size: 15px; font-weight: 700; line-height: 1.1; letter-spacing: .08em; }
.brand-name span { padding-top: 5px; color: #82877e; font-family: var(--mono); font-size: 8px; font-weight: 400; letter-spacing: .13em; }
.new-button { display: flex; align-items: center; justify-content: center; gap: 8px; width: 100%; min-height: 42px; border: 1px solid #d8ded5; border-radius: 5px; background: #f8f9f4; color: #37483b; font-size: 13px; font-weight: 600; cursor: pointer; transition: background .18s, border-color .18s; }
.new-button:hover { background: #fff; border-color: #aebdaf; }
.plus { font-size: 18px; font-weight: 400; line-height: 1; }
.library-heading { display: flex; justify-content: space-between; align-items: center; margin: 32px 9px 10px; color: #7d837a; font-family: var(--mono); font-size: 10px; letter-spacing: .11em; text-transform: uppercase; }
.library-tabs { display: grid; grid-template-columns: 1fr 1fr; gap: 3px; margin: 0 2px 10px; padding: 3px; border: 1px solid #e0e4dc; border-radius: 4px; background: #eaede6; }
.library-tabs button { min-height: 28px; border: 1px solid transparent; border-radius: 3px; background: transparent; color: #7f867c; font-size: 10px; cursor: pointer; }
.library-tabs button.active { border-color: #dce2d9; background: #fbfcf8; color: #4c664e; box-shadow: 0 1px 2px #263b260d; }
.mobile-library-tabs { display: none; }
.new-folder-button { display: flex; min-height: 30px; align-items: center; justify-content: center; gap: 6px; margin: 0 2px 9px; border: 1px dashed #cbd5c8; border-radius: 3px; background: #f7f9f4; color: #5e795f; font-size: 10px; font-weight: 600; cursor: pointer; }
.new-folder-button span { font-size: 15px; font-weight: 400; }
.new-folder-button:hover { border-color: #88a088; background: #f0f4ed; }
.mobile-new-folder { display: none; }
.folder-filter-label { display: flex; flex-direction: column; gap: 5px; margin: 2px 7px 8px; color: #90968c; font-family: var(--mono); font-size: 8px; letter-spacing: .09em; }
.folder-filter-label select { min-width: 0; height: 29px; padding: 0 7px; border: 1px solid #dfe3da; border-radius: 3px; background: #f8f9f5; color: #647061; font-family: 'DM Sans', sans-serif; font-size: 10px; letter-spacing: 0; }
.count { display: grid; width: 21px; height: 21px; place-items: center; border-radius: 50%; background: #e4e8df; color: #637262; font-size: 10px; letter-spacing: 0; }
.diagram-list { display: flex; flex-direction: column; gap: 3px; }
.diagram-link { position: relative; display: flex; align-items: center; gap: 10px; width: 100%; padding: 8px; border: 0; border-radius: 5px; background: transparent; text-align: left; cursor: pointer; transition: background .16s; }
.diagram-link:hover { background: #e9ebe4; }
.diagram-link.active { background: #e1e7df; }
.thumbnail { width: 38px; height: 38px; flex: 0 0 38px; overflow: hidden; display: grid; place-items: center; border: 1px solid #dfe2da; border-radius: 3px; background: #fff; }
.thumbnail img { width: 100%; height: 100%; object-fit: cover; }
.diagram-link-copy { display: flex; min-width: 0; flex-direction: column; gap: 4px; }
.diagram-link-title { overflow: hidden; color: #394039; font-size: 12px; font-weight: 600; text-overflow: ellipsis; white-space: nowrap; }
.diagram-link-meta { color: #92978e; font-size: 10px; }
.active-dot { display: none; position: absolute; right: 8px; width: 5px; height: 5px; border-radius: 50%; background: #5b8062; }
.diagram-link.active .active-dot { display: block; }
.library-empty { padding: 12px 9px; color: #9a9e95; font-size: 11px; line-height: 1.5; }
.sidebar-bottom { display: flex; flex-direction: column; gap: 25px; margin-top: auto; padding: 18px 8px 0; border-top: 1px solid #dfe2da; }
.save-indicator { display: flex; align-items: center; gap: 7px; color: #747e72; font-family: var(--mono); font-size: 9px; }
.save-indicator span, .local-tag span { width: 6px; height: 6px; border-radius: 50%; background: #6a936c; }
.save-indicator.save-saving span { background: #c39b52; animation: pulse 1.2s infinite; }
.save-indicator.save-error span { background: #bc695a; }
.sidebar-note { color: #9a9e95; font-family: var(--serif); font-size: 16px; font-style: italic; line-height: 1.35; }
.main-area { min-width: 0; flex: 1; padding: 0 45px 42px; }
.topbar { display: flex; min-height: 70px; justify-content: space-between; align-items: center; border-bottom: 1px solid #e4e6de; }
.breadcrumbs, .topbar-right { display: flex; align-items: center; }
.breadcrumbs { gap: 12px; color: #92968d; font-family: var(--mono); font-size: 9px; letter-spacing: .1em; }
.breadcrumbs span:last-child { color: #566354; }
.breadcrumbs i { color: #c2c5bc; font-style: normal; }
.topbar-right { gap: 15px; }
.local-tag { display: flex; align-items: center; gap: 7px; color: #838980; font-family: var(--mono); font-size: 8px; letter-spacing: .08em; }
.avatar { display: grid; width: 29px; height: 29px; place-items: center; border: 1px solid #d7ddd3; border-radius: 50%; background: #e8ede5; color: #55715b; font-family: var(--serif); font-size: 15px; }
.page-heading { display: flex; align-items: end; justify-content: space-between; gap: 20px; padding: 36px 0 27px; }
.organization-strip { display: flex; flex-wrap: wrap; align-items: end; gap: 15px 19px; margin: -12px 0 22px; padding: 12px 13px; border: 1px solid #e2e6dd; border-radius: 4px; background: #f9faf6; }
.metadata-field { display: flex; min-width: 0; flex-direction: column; gap: 6px; color: #838b80; font-family: var(--mono); font-size: 8px; letter-spacing: .1em; }
.metadata-field input, .metadata-field select { height: 30px; padding: 0 8px; border: 1px solid #dfe4db; border-radius: 3px; background: #fff; color: #465247; font-family: 'DM Sans', sans-serif; font-size: 10px; letter-spacing: 0; }
.metadata-field input::placeholder { color: #a5aba1; }
.folder-field { width: min(190px, 100%); }
.visibility-field { width: 116px; }
.tags-field { flex: 1 1 230px; }
.tag-list { display: flex; min-height: 30px; flex-wrap: wrap; align-items: center; gap: 5px; }
.topic-tag { display: inline-flex; align-items: center; gap: 5px; min-height: 23px; padding: 0 6px 0 8px; border: 1px solid #dce5d9; border-radius: 3px; background: #eff4ed; color: #587259; font-family: 'DM Sans', sans-serif; font-size: 9px; letter-spacing: 0; }
.topic-tag button { width: 14px; height: 14px; padding: 0; border: 0; background: transparent; color: #7c8d78; font-size: 13px; line-height: 1; cursor: pointer; }
.tag-entry { display: flex; height: 27px; align-items: center; border: 1px dashed #d3dbd0; border-radius: 3px; background: #fff; }
.tag-entry input { width: 90px; height: 25px; padding: 0 7px; border: 0; outline: 0; background: transparent; color: #465247; font-size: 9px; }
.tag-entry input::placeholder { color: #a5aba1; }
.tag-entry button { width: 26px; height: 25px; border: 0; background: transparent; color: #5d7b60; font-size: 15px; cursor: pointer; }
.tag-entry button:disabled { color: #b4bbb1; cursor: default; }
.share-action { display: flex; flex: 1 0 100%; justify-content: end; align-items: center; gap: 10px; margin-top: -5px; }
.share-button { display: inline-flex; align-items: center; gap: 5px; color: #547455; font-size: 10px; }
.share-button svg { width: 15px; height: 15px; }
.share-message { overflow-wrap: anywhere; color: #71816d; font-size: 9px; }
.public-readonly { display: flex; align-items: center; gap: 9px; }
.public-icon { display: grid; width: 28px; height: 28px; place-items: center; border: 1px solid #dce5d9; border-radius: 50%; color: #5f7c60; font-size: 15px; }
.public-readonly strong, .public-readonly small { display: block; }
.public-readonly strong { color: #597259; font-size: 10px; font-weight: 600; }
.public-readonly small { margin-top: 2px; color: #92998f; font-size: 9px; }
.public-tag-list { display: flex; flex-wrap: wrap; gap: 4px; margin-left: 8px; }
.eyebrow { display: flex; align-items: center; gap: 8px; color: #879084; font-family: var(--mono); font-size: 9px; letter-spacing: .13em; }
.eyebrow-line { width: 17px; height: 1px; background: #779179; }
.title-input, .page-title { display: block; max-width: 720px; margin: 9px 0 3px; padding: 0; border: 0; outline: none; background: transparent; color: #29332d; font-family: var(--serif); font-size: 38px; font-weight: 400; line-height: 1.05; }
.title-input:focus { outline: none; }
.title-input:focus-visible { outline: none; box-shadow: 0 1px #779179; }
.page-title { display: flex; align-items: center; gap: 13px; }
.subtitle { margin: 9px 0 0; color: #848a81; font-size: 12px; }
.study-label { padding: 6px 8px; border: 1px solid #d8e0d6; border-radius: 3px; color: #5d7960; font-family: var(--mono); font-size: 9px; font-weight: 400; letter-spacing: .08em; text-transform: uppercase; }
.heading-actions { display: flex; align-items: center; gap: 16px; padding-bottom: 2px; }
.text-button { padding: 8px 0; border: 0; background: none; color: #81877e; font-size: 11px; cursor: pointer; }
.text-button:hover { color: #455d49; }
.primary-button { display: inline-flex; min-height: 38px; align-items: center; justify-content: center; gap: 7px; padding: 0 14px; border: 1px solid var(--green); border-radius: 4px; background: var(--green); color: #fff; font-size: 11px; font-weight: 600; cursor: pointer; transition: background .16s, border-color .16s, transform .16s; }
.primary-button:hover:not(:disabled) { transform: translateY(-1px); border-color: var(--green-dark); background: var(--green-dark); }
.primary-button:disabled { border-color: #bdc6ba; background: #bdc6ba; cursor: not-allowed; }
.primary-button svg { width: 17px; height: 17px; }
.workbench { display: grid; grid-template-columns: minmax(0, 1fr) 285px; min-height: 390px; border: 1px solid #e2e5dc; border-radius: 5px; background: #fbfbf8; box-shadow: 0 7px 22px #273c2610; }
.image-column { min-width: 0; padding: 0 22px 12px; border-right: 1px solid #e6e8e1; }
.canvas-toolbar { display: flex; height: 50px; justify-content: space-between; align-items: center; border-bottom: 1px solid #eceee7; }
.canvas-caption { display: flex; align-items: center; gap: 8px; color: #81887f; font-family: var(--mono); font-size: 9px; letter-spacing: .09em; }
.caption-icon { color: #638064; font-size: 17px; }
.canvas-actions { display: flex; align-items: center; gap: 10px; }
.image-dimensions { color: #a0a49b; font-family: var(--mono); font-size: 9px; }
.icon-button, .add-icon { display: grid; width: 29px; height: 29px; place-items: center; border: 1px solid #e1e4dc; border-radius: 4px; background: transparent; color: #727b70; cursor: pointer; }
.icon-button:hover, .add-icon:hover { border-color: #aebcae; background: #f2f5ef; }
.icon-button svg, .add-icon svg { width: 16px; height: 16px; }
.diagram-stage { position: relative; width: 100%; margin: 17px auto 13px; cursor: default; }
.diagram-stage.placing { cursor: crosshair; }
.diagram-image { display: block; width: 100%; height: auto; user-select: none; }
.leader-lines { position: absolute; inset: 0; width: 100%; height: 100%; overflow: visible; pointer-events: none; }
.leader-lines line { stroke: #527658; stroke-width: 1.5; vector-effect: non-scaling-stroke; }
.callout-target { position: absolute; width: 1px; height: 1px; pointer-events: none; }
.target-dot { position: absolute; z-index: 1; top: -5px; left: -5px; width: 10px; height: 10px; border: 2px solid #fff; border-radius: 50%; background: #527658; box-shadow: 0 0 0 1px #527658; }
.target-circle { position: absolute; z-index: 1; aspect-ratio: 1; transform: translate(-50%, -50%); border: 1.5px solid #527658; border-radius: 50%; background: #52765820; pointer-events: none; }
.target-circle::after { position: absolute; top: 50%; left: 50%; width: 6px; height: 6px; transform: translate(-50%, -50%); border: 1px solid #fff; border-radius: 50%; background: #527658; box-shadow: 0 0 0 1px #527658; content: ''; }
.circle-draft { z-index: 4; border-style: dashed; background: #52765830; }
.callout-number { position: absolute; z-index: 2; display: flex; width: max-content; max-width: min(220px, 45vw); min-height: 22px; align-items: center; gap: 6px; padding: 3px 7px; transform: translate(-50%, -50%); border: 1px solid #456c4d; border-radius: 2px; background: #f9fbf7; color: #456c4d; box-shadow: 0 1px 4px #1e2d201c; text-align: left; cursor: grab; touch-action: none; user-select: none; }
.callout-index { display: grid; min-width: 17px; min-height: 15px; flex: 0 0 auto; place-items: center; padding-right: 5px; border-right: 1px solid #d8e1d5; color: #456c4d; font-family: var(--mono); font-size: 9px; }
.callout-label-name { min-width: 0; color: #39483a; font-family: 'DM Sans', sans-serif; font-size: 10px; font-weight: 500; line-height: 1.25; overflow-wrap: anywhere; }
.practice-number { width: 25px; min-width: 25px; height: 20px; min-height: 20px; justify-content: center; padding: 0 4px; color: #456c4d; font-family: var(--mono); font-size: 9px; text-align: center; }
.callout-number:active, .callout-number.dragging { z-index: 3; background: #eaf2e8; cursor: grabbing; }
.canvas-empty-tip { position: absolute; right: 10px; bottom: 10px; display: flex; align-items: center; gap: 6px; padding: 6px 8px; border: 1px solid #e4e8df; border-radius: 3px; background: #fbfbf2e8; color: #7c8478; font-size: 9px; }
.tip-cross { color: #537657; font-size: 14px; }
.placement-hint { position: absolute; top: 10px; left: 50%; display: flex; align-items: center; gap: 6px; padding: 8px 11px; transform: translateX(-50%); border-radius: 3px; background: #345341ed; color: #fff; font-size: 10px; white-space: nowrap; pointer-events: none; }
.placement-hint span { font-size: 14px; }
.canvas-footer { display: flex; justify-content: space-between; padding-top: 10px; border-top: 1px solid #eceee7; color: #969b92; font-family: var(--mono); font-size: 8px; letter-spacing: .05em; }
.canvas-footer > span:first-child { display: flex; align-items: center; gap: 6px; font-family: 'DM Sans', sans-serif; font-size: 9px; letter-spacing: 0; }
.footer-dot { width: 5px; height: 5px; border-radius: 50%; background: #6b916c; }
.structure-panel { display: flex; min-width: 0; flex-direction: column; padding: 19px 16px 14px; }
.panel-heading { display: flex; justify-content: space-between; align-items: center; margin-bottom: 16px; }
.panel-eyebrow { margin-bottom: 6px; font-size: 8px; }
.panel-heading h2 { margin: 0; color: #303931; font-family: var(--serif); font-size: 22px; font-weight: 400; }
.panel-heading h2 span { margin-left: 4px; color: #979c93; font-family: var(--mono); font-size: 10px; vertical-align: 3px; }
.add-icon { width: 27px; height: 27px; }
.add-structure-button { display: flex; height: 36px; align-items: center; justify-content: center; gap: 7px; border: 1px dashed #c9d2c6; border-radius: 3px; background: #f7f9f4; color: #5e795f; font-size: 10px; font-weight: 600; cursor: pointer; }
.add-structure-button:hover { border-color: #78957a; background: #f1f5ee; }
.add-structure-button span { font-size: 16px; font-weight: 400; }
.add-structure-button.active { border-style: solid; border-color: #9db59b; background: #edf4ea; color: #4e704f; }
.add-structure-button.active span { font-size: 12px; }
.placing-note { display: flex; height: 36px; align-items: center; justify-content: center; gap: 7px; border: 1px solid #d7e1d5; border-radius: 3px; background: #eef4ec; color: #537358; font-size: 10px; }
.target-type-picker { display: grid; grid-template-columns: 1fr 1fr; gap: 3px; margin-top: 8px; padding: 3px; border: 1px solid #e1e6dc; border-radius: 4px; background: #f4f6f1; }
.target-type-button { display: flex; min-height: 32px; align-items: center; justify-content: center; gap: 7px; border: 1px solid transparent; border-radius: 3px; background: transparent; color: #838a80; font-size: 10px; cursor: pointer; }
.target-type-button.selected { border-color: #d5e0d2; background: #fff; color: #4f704f; box-shadow: 0 1px 2px #273c260c; }
.point-symbol { width: 7px; height: 7px; border: 1.5px solid #668267; border-radius: 50%; background: #668267; box-shadow: 0 0 0 2px #66826725; }
.circle-symbol { width: 12px; height: 12px; border: 1.5px solid #668267; border-radius: 50%; background: #66826718; }
.placement-help { margin: 8px 1px 0; color: #858d82; font-size: 9px; line-height: 1.45; }
.pulse-dot { width: 6px; height: 6px; border-radius: 50%; background: #638c65; animation: pulse 1.5s infinite; }
.structure-list { display: flex; flex-direction: column; margin-top: 11px; }
.structure-row { display: flex; min-height: 48px; align-items: center; gap: 9px; border-bottom: 1px solid #eeefe9; }
.row-number { display: grid; width: 25px; height: 22px; flex: 0 0 25px; place-items: center; border: 1px solid #e1e6dc; border-radius: 2px; color: #61775f; font-family: var(--mono); font-size: 9px; }
.structure-name-wrap, .answer-wrap { display: flex; min-width: 0; flex: 1; flex-direction: column; }
.structure-name { width: 100%; padding: 7px 0; border: 0; background: transparent; color: #39413a; font-size: 11px; }
.public-label-name { min-width: 0; overflow-wrap: anywhere; color: #536254; font-size: 11px; }
.structure-name::placeholder { color: #a6aaa2; }
.structure-name:focus { outline: none; }
.remove-button { display: none; position: absolute; right: 0; top: 4px; width: 22px; height: 22px; border: 0; border-radius: 3px; background: #f6f3ef; color: #9b655c; font-size: 17px; cursor: pointer; }
.structure-row:hover .remove-button { display: block; }
.structure-name-wrap { position: relative; }
.structure-name-wrap:focus-within .remove-button { display: block; }
.answer-input { width: 100%; padding: 7px 0; border: 0; border-bottom: 1px solid #dfe3da; border-radius: 0; background: transparent; color: #39413a; font-size: 11px; }
.answer-input::placeholder { color: #a6aaa2; }
.answer-input:focus { outline: none; border-color: #6b8e6a; }
.answer-input:disabled { color: #39413a; opacity: 1; }
.answer-input.correct { border-color: #78a27a; color: #416b47; }
.answer-input.incorrect { border-color: #c78c7d; color: #8c5349; }
.answer-feedback { padding: 0 0 6px; color: #518057; font-size: 9px; }
.answer-wrong .answer-feedback { color: #a45f51; }
.empty-structures { display: flex; flex: 1; flex-direction: column; justify-content: center; align-items: center; padding: 26px 12px; text-align: center; }
.empty-structure-icon { display: grid; width: 37px; height: 37px; place-items: center; border: 1px solid #e2e7dd; border-radius: 50%; color: #648167; font-size: 20px; }
.empty-structures p { margin: 11px 0 4px; color: #697268; font-size: 11px; font-weight: 600; }
.empty-structures small { max-width: 165px; color: #9a9f96; font-size: 10px; line-height: 1.5; }
.panel-tip { display: flex; gap: 9px; margin-top: auto; padding: 11px 10px; border: 1px solid #eaede5; border-radius: 3px; background: #f7f8f3; }
.tip-star { color: #779075; font-size: 13px; }
.panel-tip p { margin: 0; color: #8c9288; font-size: 9px; line-height: 1.55; }
.panel-tip strong { color: #5d6e5c; font-size: 10px; font-weight: 600; }
.practice-note { margin-top: auto; padding-top: 18px; color: #92978d; font-size: 9px; text-align: center; }
.practice-note span { margin-right: 3px; font-family: var(--mono); }
.result-banner { display: flex; align-items: center; gap: 11px; margin: -11px 0 16px; padding: 10px 13px; border: 1px solid #e7ded8; border-radius: 4px; background: #f8f2ef; color: #725e57; }
.result-banner.complete { border-color: #d9e4d6; background: #f0f5ed; color: #4d6b50; }
.result-mark { font-family: var(--serif); font-size: 21px; }
.result-banner strong, .result-banner small { display: block; }
.result-banner strong { font-size: 11px; font-weight: 600; }
.result-banner small { margin-top: 2px; color: #898e84; font-size: 9px; }
.result-banner button { margin-left: auto; border: 0; background: transparent; color: #788374; font-size: 10px; cursor: pointer; }
.welcome-screen { display: grid; min-height: calc(100vh - 71px); grid-template-columns: minmax(330px, .92fr) minmax(360px, 1.08fr); align-items: center; gap: clamp(30px, 6vw, 90px); padding: 40px clamp(10px, 4vw, 60px) 55px 12px; }
.welcome-copy { max-width: 470px; padding-bottom: 10px; animation: rise-in .6s both; }
.welcome-copy h1 { margin: 21px 0 17px; color: #29342d; font-family: var(--serif); font-size: clamp(43px, 4.4vw, 63px); font-weight: 400; line-height: .98; }
.welcome-copy h1 em { color: #5d8062; font-weight: 400; }
.welcome-copy > p { max-width: 410px; margin: 0; color: #798178; font-size: 13px; line-height: 1.75; }
.welcome-button { min-height: 43px; margin-top: 26px; padding: 0 15px; font-size: 12px; }
.welcome-footnote { display: flex; align-items: center; gap: 7px; margin-top: 14px; color: #92988e; font-size: 9px; }
.welcome-footnote span { color: #789078; font-size: 15px; }
.welcome-art { position: relative; width: 100%; max-width: 520px; justify-self: end; padding: 13px 0; color: #70836e; animation: rise-in .7s .1s both; }
.welcome-art::before { position: absolute; z-index: 0; inset: 27px -12px 0 22px; border: 1px solid #e1e6dc; background: #edf0e8; content: ''; }
.art-topline, .art-bottomline { position: relative; z-index: 1; display: flex; justify-content: space-between; padding: 0 13px 10px; color: #899386; font-family: var(--mono); font-size: 8px; letter-spacing: .08em; }
.art-bottomline { padding: 10px 13px 0; }
.art-sheet { position: relative; z-index: 1; min-height: 370px; overflow: hidden; border: 1px solid #dfe4da; background: #f8f9f3; }
.art-sheet::before { position: absolute; inset: 0; background-image: radial-gradient(#74866c1f .6px, transparent .6px); background-size: 8px 8px; content: ''; opacity: .5; }
.anatomy-sketch { position: absolute; top: 50%; left: 50%; width: min(64%, 315px); max-height: 94%; transform: translate(-50%, -50%); color: #7f947a; }
.art-label { position: absolute; z-index: 1; display: flex; align-items: center; gap: 6px; padding: 5px 7px; border: 1px solid #dfe4d9; background: #fafbf6eF; color: #7b8576; font-family: var(--mono); font-size: 8px; }
.art-label b { color: #557255; font-size: 8px; font-weight: 500; }
.label-one { top: 27%; right: 4%; }
.label-two { top: 53%; left: 3%; }
.label-three { right: 7%; bottom: 18%; }
.art-seal { position: absolute; right: 18px; bottom: 14px; display: grid; width: 31px; height: 31px; place-content: center; border: 1px solid #aab8a4; border-radius: 50%; color: #71836c; font-family: var(--serif); font-size: 9px; line-height: 1.05; text-align: center; }
.visually-hidden { position: absolute; width: 1px; height: 1px; overflow: hidden; clip: rect(0, 0, 0, 0); white-space: nowrap; clip-path: inset(50%); }
.modal-scrim { position: fixed; z-index: 5; inset: 0; display: grid; place-items: center; padding: 20px; background: #1b2824a8; animation: fade-in .16s both; }
.name-modal { width: min(100%, 390px); padding: 26px; border: 1px solid #e0e4da; border-radius: 5px; background: #fbfbf8; box-shadow: 0 16px 50px #14211935; animation: rise-in .2s both; }
.modal-kicker { display: flex; justify-content: space-between; color: #82907f; font-family: var(--mono); font-size: 9px; letter-spacing: .12em; }
.modal-kicker span { color: #59755a; }
.name-modal h2 { margin: 13px 0 5px; color: #303a32; font-family: var(--serif); font-size: 27px; font-weight: 400; }
.name-modal p { margin: 0 0 22px; color: #858b82; font-size: 11px; line-height: 1.55; }
.modal-label { display: block; margin-bottom: 7px; color: #7c8678; font-family: var(--mono); font-size: 8px; letter-spacing: .1em; }
.modal-input { width: 100%; height: 40px; padding: 0 10px; border: 1px solid #dce2d9; border-radius: 3px; background: #fff; color: #39433b; font-size: 12px; }
.modal-input::placeholder { color: #acb2a8; }
.modal-actions { display: flex; justify-content: end; align-items: center; gap: 17px; margin-top: 20px; }
.auth-screen { display: grid; width: 100%; min-height: 100vh; grid-template-columns: minmax(370px, .92fr) minmax(400px, 1.08fr); align-items: center; gap: clamp(40px, 9vw, 140px); padding: 48px clamp(32px, 9vw, 140px); background: #f5f5f0; }
.auth-card { width: min(100%, 460px); justify-self: end; padding-bottom: 8px; animation: rise-in .55s both; }
.auth-brand { margin: 0 0 54px; }
.auth-card h1 { margin: 20px 0 12px; color: #29342d; font-family: var(--serif); font-size: 48px; font-weight: 400; line-height: .98; }
.auth-card h1 em { color: #5d8062; font-weight: 400; }
.auth-description { max-width: 390px; margin: 0; color: #798178; font-size: 12px; line-height: 1.7; }
.setup-steps { display: flex; flex-direction: column; gap: 18px; margin: 28px 0; padding: 0; list-style: none; }
.setup-steps li { display: flex; gap: 12px; align-items: start; }
.setup-steps li > span { padding-top: 2px; color: #6f886c; font-family: var(--mono); font-size: 9px; }
.setup-steps p { margin: 0; color: #707970; font-size: 11px; line-height: 1.65; }
.setup-steps code { padding: 2px 4px; border: 1px solid #e2e5dd; border-radius: 2px; background: #f9faf6; color: #566a55; font-family: var(--mono); font-size: 9px; }
.setup-link { display: inline-flex; align-items: center; gap: 8px; color: #537253; font-size: 11px; font-weight: 600; text-decoration: none; }
.setup-link:hover { color: #345341; }
.auth-form { display: flex; flex-direction: column; margin-top: 27px; }
.auth-form label { margin: 0 0 7px; color: #7c8678; font-family: var(--mono); font-size: 8px; letter-spacing: .1em; }
.auth-form input { height: 41px; margin-bottom: 17px; padding: 0 11px; border: 1px solid #dce2d9; border-radius: 3px; background: #fff; color: #39433b; font-size: 12px; }
.auth-form input::placeholder { color: #acb2a8; }
.auth-submit { min-height: 42px; margin-top: 4px; font-size: 12px; }
.auth-submit:disabled { cursor: wait; }
.auth-switch { display: block; margin-top: 18px; padding: 5px 0; border: 0; background: transparent; color: #688066; font-size: 10px; cursor: pointer; }
.auth-switch:hover { color: #345341; }
.auth-message, .auth-error { margin: -4px 0 15px; color: #557558; font-size: 10px; line-height: 1.5; }
.auth-error { color: #a4584a; }
.auth-illustration { position: relative; width: min(100%, 530px); justify-self: start; color: #70836e; animation: rise-in .7s .1s both; }
.auth-illustration .art-topline, .auth-illustration .art-bottomline { padding-right: 8px; padding-left: 8px; }
.auth-plate { position: relative; display: grid; min-height: 490px; place-items: center; overflow: hidden; border: 1px solid #dfe4da; background-color: #f8f9f3; background-image: radial-gradient(#74866c1f .6px, transparent .6px); background-size: 8px 8px; }
.auth-plate::before { position: absolute; inset: 13px; border: 1px solid #e8ebe4; content: ''; }
.auth-plate .anatomy-sketch { width: min(64%, 320px); max-height: 92%; }
.auth-plate-label { position: absolute; right: 18px; bottom: 18px; color: #899386; font-family: var(--mono); font-size: 8px; letter-spacing: .08em; }
.app-alert { display: flex; justify-content: space-between; align-items: start; gap: 12px; margin-top: 15px; padding: 10px 12px; border: 1px solid #ead8d2; border-radius: 3px; background: #fbf3f0; color: #8b5145; font-size: 10px; line-height: 1.5; }
.app-alert button { flex: 0 0 auto; padding: 0 2px; border: 0; background: transparent; color: inherit; font-size: 17px; line-height: 1; cursor: pointer; }
.import-banner { display: flex; justify-content: space-between; align-items: center; gap: 15px; margin-top: 14px; padding: 11px 13px; border: 1px solid #dce5d9; border-radius: 4px; background: #f0f5ed; }
.import-banner strong, .import-banner small { display: block; }
.import-banner strong { color: #526d52; font-size: 10px; font-weight: 600; }
.import-banner small { margin-top: 3px; color: #838d7f; font-size: 9px; line-height: 1.4; }
.import-banner .primary-button { flex: 0 0 auto; }
.loading-state { display: flex; align-items: center; gap: 9px; min-height: 140px; justify-content: center; color: #778174; font-size: 11px; }
@keyframes pulse { 50% { opacity: .35; box-shadow: 0 0 0 4px #638c6520; } }
@keyframes rise-in { from { opacity: 0; transform: translateY(8px); } to { opacity: 1; transform: translateY(0); } }
@keyframes fade-in { from { opacity: 0; } to { opacity: 1; } }

@media (max-width: 1050px) {
  .sidebar { width: 220px; flex-basis: 220px; }
  .main-area { padding-right: 25px; padding-left: 25px; }
  .workbench { grid-template-columns: minmax(0, 1fr) 255px; }
  .welcome-screen { gap: 28px; padding-right: 0; }
  .welcome-copy h1 { font-size: 50px; }
  .auth-screen { gap: 35px; padding-right: 50px; padding-left: 50px; }
  .auth-card h1 { font-size: 43px; }
  .auth-plate { min-height: 420px; }
}
@media (max-width: 780px) {
  .sidebar { width: 67px; flex-basis: 67px; align-items: center; padding: 20px 8px; }
  .brand { margin: 0 0 28px; }
  .brand-name, .new-button:not(:has(.plus)), .library-heading, .diagram-link-copy, .active-dot, .sidebar-bottom { display: none; }
  .sidebar .library-tabs, .sidebar .folder-filter-label { display: none; }
  .sidebar .new-folder-button { display: none; }
  .new-button { width: 42px; min-width: 42px; padding: 0; font-size: 0; }
  .new-button .plus { font-size: 22px; }
  .diagram-list { width: 100%; margin-top: 14px; }
  .diagram-link { justify-content: center; padding: 5px 0; }
  .thumbnail { width: 40px; height: 40px; flex-basis: 40px; }
  .main-area { padding: 0 20px 30px; }
  .mobile-library-tabs { display: flex; flex-wrap: wrap; align-items: center; gap: 5px; padding: 10px 0 2px; }
  .mobile-library-tabs > button { min-height: 30px; padding: 0 10px; border: 1px solid #e0e4dc; border-radius: 3px; background: #f8f9f5; color: #727b70; font-size: 10px; }
  .mobile-library-tabs > button.active { border-color: #cbd8c9; background: #eaf0e8; color: #4c664e; }
  .mobile-library-tabs .mobile-new-folder { display: inline-flex; min-height: 30px; margin: 0; padding: 0 9px; border: 1px dashed #cbd5c8; background: #f7f9f4; color: #5e795f; }
  .mobile-filter { display: flex; align-items: center; gap: 5px; color: #858c81; font-size: 9px; }
  .mobile-filter select { max-width: 140px; height: 29px; padding: 0 6px; border: 1px solid #dfe3da; border-radius: 3px; background: #f8f9f5; color: #647061; font-size: 9px; }
  .page-heading { align-items: start; flex-direction: column; gap: 16px; padding-top: 27px; }
  .organization-strip { margin-top: -6px; }
  .heading-actions { width: 100%; justify-content: space-between; }
  .workbench { grid-template-columns: minmax(0, 1fr); }
  .image-column { border-right: 0; }
  .structure-panel { border-top: 1px solid #e6e8e1; }
  .structure-list { max-height: 360px; overflow: auto; }
  .panel-tip { margin-top: 20px; }
  .welcome-screen { min-height: auto; grid-template-columns: minmax(0, 1fr); padding: 65px 0 20px; }
  .welcome-copy { max-width: 530px; }
  .welcome-art { max-width: 470px; justify-self: center; margin-top: 10px; }
  .auth-screen { min-height: 100vh; grid-template-columns: minmax(0, 1fr); justify-items: center; padding: 38px 25px; }
  .auth-card { justify-self: center; }
  .auth-brand { margin-bottom: 42px; }
  .auth-illustration { display: none; }
}
@media (max-width: 480px) {
  .sidebar { width: 54px; flex-basis: 54px; padding: 16px 5px; }
  .brand-mark, .brand-mark svg { width: 31px; height: 31px; }
  .new-button { width: 38px; min-width: 38px; min-height: 38px; }
  .thumbnail { width: 36px; height: 36px; flex-basis: 36px; }
  .main-area { padding-right: 13px; padding-left: 13px; }
  .organization-strip { gap: 10px; padding: 10px; }
  .folder-field { width: min(145px, 100%); }
  .visibility-field { width: 102px; }
  .topbar { min-height: 57px; }
  .local-tag { display: none; }
  .title-input, .page-title { font-size: 31px; }
  .page-title { align-items: start; flex-direction: column; gap: 7px; }
  .heading-actions { gap: 10px; }
  .heading-actions .text-button { font-size: 10px; }
  .primary-button { padding: 0 10px; font-size: 10px; }
  .workbench { min-height: 300px; }
  .image-column { padding-right: 12px; padding-left: 12px; }
  .canvas-footer { font-size: 7px; }
  .canvas-footer > span:first-child { font-size: 8px; }
  .welcome-copy h1 { font-size: 43px; }
  .welcome-art { width: calc(100% - 13px); }
  .art-sheet { min-height: 310px; }
  .art-label { font-size: 7px; }
  .label-two { left: 1%; }
  .label-one { right: 1%; }
  .label-three { right: 2%; }
}
</style>
